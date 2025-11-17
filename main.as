array<string> profiles = {};
int currentProfileIndex = 0;

Json::Value@ dataRoot = Json::Object();
bool showCPOverlay = true;
bool windowVisible = true;

float lastRenderTime = 0.0;
float cpOverlayTimer = 0.0;
string cpOverlayText = "";
vec4 cpOverlayColor = vec4(1, 1, 1, 1);
string newProfileName = "";

string DataFilePath() {
    return IO::FromStorageFolder("player_times.json");
}

class ProfileManager {
    void Load() {
        string path = DataFilePath();
        if (!IO::FileExists(path)) {
            @dataRoot = Json::Object();
            Save();
            return;
        }
        @dataRoot = Json::FromFile(path);
        if (dataRoot is null) @dataRoot = Json::Object();

        if (dataRoot.HasKey("profiles")) {
            profiles.RemoveRange(0, profiles.Length);
            Json::Value@ arr = dataRoot["profiles"];
            for (uint i = 0; i < arr.Length; i++) {
                profiles.InsertLast(string(arr[i]));
            }
        }
    }

    void Save() {
        string path = DataFilePath();

        dataRoot["profiles"] = Json::Array();
        for (uint i = 0; i < profiles.Length; i++) {
            dataRoot["profiles"].Add(Json::Value(profiles[i]));
        }

        IO::File f(path, IO::FileMode::Write);
        f.Write(Json::Write(dataRoot));
        f.Close();
    }

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
        }
    }

    void SetBestTimeForMap(const string &in profile, const string &in mapUid, uint finishTime, const Json::Value@ cpsJson) {
        if (!dataRoot.HasKey(profile)) dataRoot[profile] = Json::Object();
        Json::Value@ prof = dataRoot[profile];
        Json::Value@ mapObj = Json::Object();
        mapObj["finish"] = Json::Value(int(finishTime));
        mapObj["checkpoints"] = cpsJson;
        prof[mapUid] = mapObj;
        Save();
    }
}

string GetCurrentMapUid() {
    auto app = GetApp();
    if (app is null || app.RootMap is null || app.RootMap.MapInfo is null) return "";
    return app.RootMap.MapInfo.MapUid;
}

class FinishHandler {
    uint NOT_STARTED = 4294967295;
    bool raceStarted = false;
    int startGameTime = -1;
    int lastCheckpointIndex = -1;
    int lastState = -1;
    int cpIdx = 0;

    ProfileManager pm;

    FinishHandler(ProfileManager@ pmanager) {
        pm = pmanager;
    }

    void Update(float dt) {
        if (profiles.Length == 0) return;
        if (currentProfileIndex < 0 || currentProfileIndex >= int(profiles.Length)) return;

        string profile = profiles[currentProfileIndex];
        if (profile == "") return;

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

        if (raceStartVal != NOT_STARTED && !raceStarted) {
            raceStarted = true;
            startGameTime = gameTime;
            lastCheckpointIndex = -1;
            cpIdx = 0;
            cpOverlayTimer = 0;
        }

        if (raceStartVal == NOT_STARTED) {
            raceStarted  = false;
            startGameTime = -1;
            lastCheckpointIndex = -1;
            cpIdx = 0;
            cpOverlayTimer = 0;
        }

        int mapCpIdx = player.CurrentLaunchedRespawnLandmarkIndex;

        if (raceStarted && mapCpIdx != lastCheckpointIndex && mapCpIdx >= 0) {
            lastCheckpointIndex = mapCpIdx;

            if (cpIdx != 0) {
                int elapsed = (gameTime >= 0 && startGameTime >= 0) ? (gameTime - startGameTime) : -1;

                if (elapsed >= 0) {
                    string mapUid = GetCurrentMapUid();

                    uint pbSplit = pm.GetCheckpointPB(profile, mapUid, uint(cpIdx - 1));

                    if (pbSplit > 0) {
                        int diff = int(elapsed) - int(pbSplit);
                        string sign = diff > 0 ? "+" : "-";
                        cpOverlayText = sign + Time::Format(Math::Abs(diff));
                        cpOverlayColor = (diff < 0) ? vec4(0,0,1,1) : vec4(1,0,0,1);
                        cpOverlayTimer = 3.0;
                    } else {
                        cpOverlayText = Time::Format(elapsed);
                        cpOverlayColor = vec4(1,1,1,1);
                    }
                }
            }
            cpIdx++;
        }

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
            for (uint i = 0; i < ghost.Result.Checkpoints.Length; i++) {
                cpsJson[""+i] = Json::Value(int(ghost.Result.Checkpoints[i]));
            }

            string mapUid = GetCurrentMapUid();

            if (mapUid != "") {
                for (uint i = 0; i < ghost.Result.Checkpoints.Length; i++) {
                    pm.UpdateCheckpointPB(profile, mapUid, i, ghost.Result.Checkpoints[i]);
                }

                pm.Save();

                uint finishTime = ghost.Result.Time;
                uint best = pm.GetBestTimeForMap(profile, mapUid);

                if (best == 0 || finishTime < best) {
                    pm.SetBestTimeForMap(profile, mapUid, finishTime, cpsJson);
                    UI::ShowNotification("LocalProfiles", "🏁 We PB for " + profile + " : " + Time::Format(finishTime));
                }
            }

            rules.DataFileMgr.Ghost_Release(ghost.Id);
        }

        lastState = state;
    }
}

void RenderCPOverlay() {
    if (cpOverlayTimer > 0.0) {
        cpOverlayTimer -= 1.0 / 88.0;

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
        nvg::FillColor(vec4(1,1,1,1)); 
        nvg::Text(pos, cpOverlayText);

        nvg::Restore();
    }
}

void RenderProfilesTable(const string &in mapUid) {
    if (!UI::BeginTable("ProfilesTable", 3, UI::TableFlags::SizingFixedFit)) return;
    UI::TableNextRow();
    UI::TableNextColumn(); UI::Text("Profile");
    UI::TableNextColumn(); UI::Text("Finish");
    UI::TableNextColumn(); UI::Text("Del");

    ProfileManager pm;

    for (uint i = 0; i < profiles.Length; i++) {
        UI::TableNextRow();
        UI::TableNextColumn();
        string label = (int(i) == currentProfileIndex ? "\\$8f8" : "") + profiles[i];
        if (UI::Selectable(label, int(i) == currentProfileIndex)) {
            currentProfileIndex = int(i);
        }
        UI::TableNextColumn();
        uint best = pm.GetBestTimeForMap(profiles[i], mapUid);
        UI::Text(best == 0 ? "-" : Time::Format(best));
        UI::TableNextColumn();
        if (UI::Button("×##del" + i)) {
            profiles.RemoveAt(i);
            if (currentProfileIndex >= int(profiles.Length))
                currentProfileIndex = Math::Max(0, profiles.Length - 1);
            pm.Save();
            break;
        }
    }
    UI::EndTable();
}

void RenderAddProfileSection() {
    UI::Separator();
    UI::Text("Add new profile:");

    UI::PushItemWidth(120);
    newProfileName = UI::InputText(" ", newProfileName);
    UI::PopItemWidth();

    if (UI::Button("Add")) {
        string trimmed = newProfileName.Trim();
        if (trimmed.Length > 0) {
            profiles.InsertLast(trimmed);
            newProfileName = "";
            ProfileManager pm;
            pm.Save();
        }
    }
}

void Render() {
    auto app = cast<CTrackMania>(GetApp());
    if (app is null || app.RootMap is null || app.Editor !is null) return;

    string mapUid = GetCurrentMapUid();
    if (mapUid == "") return;

    if (UI::IsKeyPressed(UI::Key::B)) {
        if (profiles.Length > 0) {
            currentProfileIndex = (currentProfileIndex + 1) % profiles.Length;
        }
    }

    UI::SetNextWindowPos(1600, 100, UI::Cond::FirstUseEver);
    int flags = UI::WindowFlags::NoTitleBar | UI::WindowFlags::NoCollapse | UI::WindowFlags::AlwaysAutoResize;
    UI::PushStyleColor(UI::Col::WindowBg, vec4(26/255.0, 27/255.0, 26/255.0, 1));

    if (UI::Begin("LocalProfiles", flags)) {
        UI::Text("\\$fffLocal Profiles (B to switch)");
        UI::Separator();
        if (UI::Button(showCPOverlay ? "Hide splits" : "Show splits")) {
            showCPOverlay = !showCPOverlay;
        }

        RenderProfilesTable(mapUid);
        RenderAddProfileSection();

        if (showCPOverlay) RenderCPOverlay();

        UI::End();
    }
    UI::PopStyleColor();
}

void Main() {
    ProfileManager pm;
    pm.Load();

    FinishHandler handler(pm);

    while (true) {
        handler.Update(0);
        yield();
    }
}
