// =======================================
// Local Profiles Overlay (style Medals++)
// PB finish + PB checkpoints + color overlay
// =======================================

const string kDataFileName = "two_player_local_records.json";
array<string> profiles = {};
int currentProfileIndex = 0;
UI::Font@ font = null;
string loadedFontFace = "";
int loadedFontSize = 14;
int fontSize = 14;

Json::Value@ dataRoot = Json::Object();
vec2 anchor = vec2(1600, 100);
bool showCPOverlay = true;
bool windowVisible = true;

float lastRenderTime = 0.0;
float cpOverlayTimer = 0.0;
string cpOverlayText = "";
vec4 cpOverlayColor = vec4(1, 1, 1, 1); // par défaut blanc
string newProfileName = "";


// -----------------------------
// Helpers : chargement / sauvegarde
// -----------------------------
string DataFilePath() {
    return IO::FromUserGameFolder(kDataFileName);
}

void LoadData() {
    string path = DataFilePath();
    if (!IO::FileExists(path)) {
        trace("[LocalProfiles] No save file detected creating one");
        @dataRoot = Json::Object();
        dataRoot["overlay_x"] = anchor.x;
        dataRoot["overlay_y"] = anchor.y;
        SaveData();
        return;
    }
    @dataRoot = Json::FromFile(path);
    if (dataRoot is null) @dataRoot = Json::Object();
    if (dataRoot.HasKey("overlay_x")) anchor.x = dataRoot["overlay_x"];
    if (dataRoot.HasKey("overlay_y")) anchor.y = dataRoot["overlay_y"];

    if (dataRoot.HasKey("profiles")) {
        profiles.RemoveRange(0, profiles.Length);
        Json::Value@ arr = dataRoot["profiles"];
        for (uint i = 0; i < arr.Length; i++) {
            profiles.InsertLast(string(arr[i]));
        }
    }
}

void SaveData() {
    string path = DataFilePath();
    string folder = Path::GetDirectoryName(path);
    if (!IO::FolderExists(folder)) IO::CreateFolder(folder, true);

    dataRoot["overlay_x"] = anchor.x;
    dataRoot["overlay_y"] = anchor.y;

    dataRoot["profiles"] = Json::Array();
    for (uint i = 0; i < profiles.Length; i++) {
        dataRoot["profiles"].Add(Json::Value(profiles[i]));
    }

    IO::File f(path, IO::FileMode::Write);
    f.Write(Json::Write(dataRoot));
    f.Close();
}


// -----------------------------
// JSON helpers
// -----------------------------
Json::Value@ EnsureMapObject(const string &in profile, const string &in mapUid) {
    if (!dataRoot.HasKey(profile)) {
        dataRoot[profile] = Json::Object();
    }
    Json::Value@ prof = dataRoot[profile];
    if (!prof.HasKey(mapUid)) {
        prof[mapUid] = Json::Object();
    }
    return prof[mapUid];
}

uint GetBestTimeForMap(const string &in profile, const string &in mapUid) {
    if (!dataRoot.HasKey(profile)) return 0;
    if (!dataRoot[profile].HasKey(mapUid)) return 0;
    Json::Value@ mapObj = dataRoot[profile][mapUid];
    if (mapObj is null) return 0;
    if (mapObj.HasKey("finish")) return uint(mapObj["finish"]);
    return 0;
}

uint GetCheckpointPB(const string &in profile, const string &in mapUid, uint idx) {
    if (!dataRoot.HasKey(profile)) return 0;
    Json::Value@ prof = dataRoot[profile];
    if (prof is null) return 0;
    if (!prof.HasKey(mapUid)) return 0;
    Json::Value@ mapObj = prof[mapUid];
    if (mapObj is null) return 0;
    if (!mapObj.HasKey("checkpoints")) return 0;
    Json::Value@ cps = mapObj["checkpoints"];
    string key = "" + idx;
    if (!cps.HasKey(key)) return 0;
    return uint(cps[key]);
}

void UpdateCheckpointPB(const string &in profile, const string &in mapUid, uint idx, uint timeMs) {
    Json::Value@ mapObj = EnsureMapObject(profile, mapUid);
    if (!mapObj.HasKey("checkpoints")) {
        mapObj["checkpoints"] = Json::Object();
    }
    Json::Value@ cpsObj = mapObj["checkpoints"];
    string key = "" + idx;
    uint prev = 0;
    if (cpsObj.HasKey(key)) prev = uint(cpsObj[key]);
    if (prev == 0 || timeMs < prev) {
        cpsObj[key] = Json::Value(int(timeMs));
        SaveData();
    }
}

void SetBestTimeForMap(const string &in profile, const string &in mapUid, uint finishTime, const Json::Value@ cpsJson) {
    if (!dataRoot.HasKey(profile)) dataRoot[profile] = Json::Object();
    Json::Value@ prof = dataRoot[profile];
    Json::Value@ mapObj = Json::Object();
    mapObj["finish"] = Json::Value(int(finishTime));
    mapObj["checkpoints"] = cpsJson;
    prof[mapUid] = mapObj;
    SaveData();
}


// -----------------------------
// Utils
// -----------------------------
string FormatTime(uint t) {
    int m = t / 60000;
    int s = (t % 60000) / 1000;
    int ms = t % 1000;

    string str = "";
    if (m < 10) str += "0";
    str += "" + m + ":";

    if (s < 10) str += "0";
    str += "" + s + ".";

    if (ms < 10) str += "00";
    else if (ms < 100) str += "0";
    str += "" + ms;

    return str;
}

string GetCurrentMapUid() {
    auto app = GetApp();
    if (app is null || app.RootMap is null || app.RootMap.MapInfo is null) return "";
    return app.RootMap.MapInfo.MapUid;
}


// -----------------------------
// FINISH HANDLER
// -----------------------------
class FinishHandler {
    uint NOT_STARTED = 4294967295;
    bool raceStarted = false;
    int startGameTime = -1;
    int lastCheckpointIndex = -1;
    int lastState = -1;
    int cpIdx = 0;

    void Update(float dt) {
        auto app = GetApp();
        if (app is null || app.CurrentPlayground is null) return;
        if (app.CurrentPlayground.UIConfigs.Length == 0) return;

        int state = app.CurrentPlayground.UIConfigs[0].UISequence;
        auto playground = cast<CSmArenaClient>(app.CurrentPlayground);
        if (playground is null) return;
        auto term = playground.GameTerminals[0];
        if (term is null || term.GUIPlayer is null) return;
        CSmPlayer@ player = cast<CSmPlayer>(term.GUIPlayer);
        if (player is null) return;

        int gameTime = -1;
        auto netScript = cast<CGameScriptHandlerPlaygroundInterface>(app.Network.PlaygroundInterfaceScriptHandler);
        if (netScript !is null) gameTime = netScript.GameTime;

        ISceneVis@ scene = app.GameScene;
        if (scene is null) return;
        CSceneVehicleVis@[] cars = VehicleState::GetAllVis(scene);
        if (cars.Length == 0) return;

        uint raceStartVal = cars[0].AsyncState.RaceStartTime;

        // Début de course
        if (raceStartVal != NOT_STARTED && !raceStarted) {
            raceStarted = true;
            startGameTime = gameTime;
            lastCheckpointIndex = -1;
            cpIdx = 0;
            cpOverlayTimer = 0;
        }

        // Reset si retour menu ou avant la course
        if (raceStartVal == NOT_STARTED) {
            raceStarted = false;
            startGameTime = -1;
            lastCheckpointIndex = -1;
            cpIdx = 0;
            cpOverlayTimer = 0;
        }

        int mapCpIdx = player.CurrentLaunchedRespawnLandmarkIndex;

        if (raceStarted && mapCpIdx != lastCheckpointIndex && mapCpIdx >= 0) {
            lastCheckpointIndex = mapCpIdx;

            if (cpIdx == 0) {

            } else {
                int elapsed = (gameTime >= 0 && startGameTime >= 0) ? (gameTime - startGameTime) : -1;
                if (elapsed >= 0) {
                    string profile = profiles[currentProfileIndex];
                    string mapUid = GetCurrentMapUid();

                    uint pbSplit = GetCheckpointPB(profile, mapUid, uint(cpIdx - 1));
                    if (pbSplit > 0) {
                        int diff = int(elapsed) - int(pbSplit);
                        string sign = diff > 0 ? "+" : "-";
                        cpOverlayText = sign + FormatTime(uint(Math::Abs(diff)));
                        cpOverlayColor = diff < 0 ? vec4(0,0,1,1) : vec4(1,0,0,1);

                        cpOverlayTimer = 3.0;
                    } else {
                        cpOverlayText = FormatTime(uint(elapsed));
                        cpOverlayColor = vec4(1,1,1,1);
                    }
                }
            }
            cpIdx = cpIdx + 1;
        }

        // Fin de course : récupération et mise à jour des PB
        if (state != lastState && state == SGamePlaygroundUIConfig::EUISequence::Finish) {
            auto rules = cast<CSmArenaRulesMode>(app.PlaygroundScript);
            if (rules is null) { lastState = state; return; }
            auto termFinish = app.CurrentPlayground.GameTerminals[0];
            if (termFinish is null || termFinish.GUIPlayer is null) { lastState = state; return; }
            CSmPlayer@ smp = cast<CSmPlayer>(termFinish.GUIPlayer);
            if (smp is null || smp.ScriptAPI is null) { lastState = state; return; }
            CSmScriptPlayer@ scr = cast<CSmScriptPlayer>(smp.ScriptAPI);
            if (scr is null) { lastState = state; return; }

            auto ghost = rules.Ghost_RetrieveFromPlayer(scr);
            if (ghost is null || ghost.Result is null) { lastState = state; return; }

            Json::Value@ cpsJson = Json::Object();
            for (uint i = 0; i < ghost.Result.Checkpoints.get_Length(); i++) {
                cpsJson["" + i] = Json::Value(int(ghost.Result.Checkpoints.opIndex(i)));
            }

            string mapUid = GetCurrentMapUid();
            string profile = profiles[currentProfileIndex];
            if (mapUid != "" && profile != "") {
                for (uint i = 0; i < ghost.Result.Checkpoints.get_Length(); i++) {
                    UpdateCheckpointPB(profile, mapUid, i, ghost.Result.Checkpoints.opIndex(i));
                }

                uint finishTime = ghost.Result.Time;
                uint best = GetBestTimeForMap(profile, mapUid);
                if (best == 0 || finishTime < best) {
                    SetBestTimeForMap(profile, mapUid, finishTime, cpsJson);
                    UI::ShowNotification("LocalProfiles", "🏁 Nouveau record pour " + profile + " : " + FormatTime(finishTime));
                }
            }
            rules.DataFileMgr.Ghost_Release(ghost.Id);
        }

        lastState = state;
    }
}



// -----------------------------
// UI Overlay
// -----------------------------
void LoadFont() {
    string fontFace = "DroidSans.ttf";
    if (fontFace != loadedFontFace || fontSize != loadedFontSize) {
        @font = UI::LoadFont(fontFace, fontSize);
        if (font !is null) {
            loadedFontFace = fontFace;
            loadedFontSize = fontSize;
        }
    }
}

void RenderCPOverlay() {
    if (cpOverlayTimer > 0.0) {
        cpOverlayTimer -= 1.0 / 88.0;  // On suppose un update à 60 FPS, décrémente de ~0.0167s par frame

        vec2 screenSize = vec2(Draw::GetWidth(), Draw::GetHeight());
        vec2 pos = vec2((screenSize.x / 2.0) - 8,  (screenSize.y / 3.034));

        nvg::Save();

        nvg::FontSize(48);
        nvg::TextAlign(nvg::Align::Center | nvg::Align::Middle);

        float rectWidth = 144.0;
        float rectHeight = 59.0;
        vec2 rectPos = pos - vec2(rectWidth / 2, rectHeight / 2);

        nvg::BeginPath();
        nvg::Rect(rectPos.x, rectPos.y, rectWidth, rectHeight);
        nvg::FillColor(cpOverlayColor);
        nvg::Fill();

        nvg::FontSize(28);
        nvg::FillColor(vec4(1,1,1,1));  // alpha = 1, opaque
        nvg::Text(pos, cpOverlayText);

        nvg::Restore();
    }
}





void Render() {
    auto app = cast<CTrackMania>(GetApp());
    if (app is null || app.RootMap is null || app.Editor !is null) return;

    string mapUid = GetCurrentMapUid();
    if (mapUid == "") return;

    if (UI::IsKeyPressed(UI::Key::S)) {
        if (profiles.Length > 0) {
            currentProfileIndex = (currentProfileIndex + 1) % profiles.Length;
            SaveData();
        }
    }

    UI::SetNextWindowPos(int(anchor.x), int(anchor.y), UI::Cond::FirstUseEver);
    int flags = UI::WindowFlags::NoTitleBar | UI::WindowFlags::NoCollapse | UI::WindowFlags::AlwaysAutoResize;
    UI::PushStyleColor(UI::Col::WindowBg, vec4(26/255.0, 27/255.0, 26/255.0, 1));

    if (UI::Begin("LocalProfiles++", flags)) {
        anchor = UI::GetWindowPos();
        LoadFont();
        UI::PushFont(font);
        UI::Text("\\$fffLocal Profiles");
        UI::Separator();
        if (UI::Button(showCPOverlay ? "Hide splits" : "Show splits")) {
            showCPOverlay = !showCPOverlay;
        }
        if (UI::BeginTable("ProfilesTable", 3, UI::TableFlags::SizingFixedFit)) {
            UI::TableNextRow();
            UI::TableNextColumn(); UI::Text("Profile");
            UI::TableNextColumn(); UI::Text("Finish");
            UI::TableNextColumn(); UI::Text("Del");
            for (uint i = 0; i < profiles.Length; i++) {
                UI::TableNextRow();
                UI::TableNextColumn();
                string label = (i == currentProfileIndex ? "\\$8f8" : "") + profiles[i];
                if (UI::Selectable(label, i == currentProfileIndex)) {
                    currentProfileIndex = i;
                    SaveData();
                }
                UI::TableNextColumn();
                uint best = GetBestTimeForMap(profiles[i], mapUid);
                UI::Text(best == 0 ? "-" : FormatTime(best));
                UI::TableNextColumn();
                if (UI::Button("×##del" + i)) {
                    profiles.RemoveAt(i);
                    if (currentProfileIndex >= int(profiles.Length))
                        currentProfileIndex = Math::Max(0, profiles.Length - 1);
                    SaveData();
                    break;
                }
            }
            UI::EndTable();
        }
        UI::PopFont();
    }
    // --- Nouvelle section : ajout de profil ---
    UI::Separator();
    UI::Text("Add new profile:");

    UI::PushItemWidth(120);
    newProfileName = UI::InputText(" ", newProfileName);
    UI::PopItemWidth();

    if (UI::Button("Add")) {
        string trimmed = newProfileName.Trim();
        trace(trimmed);

        if (trimmed.Length > 0) {

            profiles.InsertLast(trimmed);
            newProfileName = ""; 
            SaveData();
        }
    }
    if (showCPOverlay) RenderCPOverlay();
    UI::End();
    UI::PopStyleColor();
}



// -----------------------------
// MAIN
// -----------------------------
void Main() {
    LoadData();
    FinishHandler handler;
    while (true) {
        handler.Update(0);
        yield();
    }
}
