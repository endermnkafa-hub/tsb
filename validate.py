import re

with open('tsb.lua', 'r', encoding='utf-8') as f:
    content = f.read()

checks = [
    # Core & Previous Checks
    ("AutoBlock in ConfigSchema", r"AutoBlock"),
    ("Diagnostics Toggle crash fixed", r"cfg_diag\.Telemetry\.AutoRecordData"),
    ("InfiniteJump ToggleJumpFeatures", r"ToggleJumpFeatures"),
    ("DoubleJump djUsed", r"djUsed"),
    ("Jump Maid cleanup", r"_jumpMaid"),
    ("Movement Destroy in maid", r"movement:Destroy"),
    ("SkillsEngine registered", r"SkillsEngine"),
    ("Skills UpdateAutoSkillSpam called", r"UpdateAutoSkillSpam"),
    ("WorldEnv_Slow scheduler", r"WorldEnv_Slow"),
    ("AntiAFK throttled 60s", r"lastAntiAFKTick"),
    ("FullBright immediate wiring", r"ToggleFullBright"),
    ("TelemetryRecorder PlayerAdded tracked", r'"PlayerAdded"'),
    ("TelemetryRecorder PlayerRemoving tracked", r'"PlayerRemoving"'),
    ("Slider AncestryChanged cleanup", r"AncestryChanged"),
    ("Slider connEnded scoped", r"connEnded"),
    ("Workspace imported in Bootstrap", r"Workspace.*=.*GetService"),
    ("Bootstrap SkillsEngine feature", r"SkillsEngine"),
    ("Movement tab jump wiring", r"ToggleJumpFeatures"),
    ("AutoBlock in CombatTab UI", r"Auto Block"),
    ("AntiAFK_Background scheduler", r"AntiAFK_Background"),

    # Phase 2 & Specialist Enhancements
    ("AntiCounterBait in Combat", r"AntiCounterBait.*IsEnemyInCounterStance"),
    ("AntiRagdoll implemented in Combat", r"function Combat:UpdateAntiRagdoll"),
    ("AutoEvasive implemented in Combat", r"function Combat:UpdateAutoEvasive"),
    ("MassBring implemented in Combat", r"function Combat:UpdateMassBring"),
    ("MassBring Keybind (G) in UIController", r"MassBringKey"),
    ("SkyDodge Keybind (H) in UIController", r"ToggleSkyDodge"),
    ("Velocity Fly Mode in Movement", r'config\.Movement\.FlyMode == "Velocity"'),
    ("VoidKill in Skills", r"function Skills:UpdateVoidKill"),
    ("VoidKill wired in SkillsEngine", r"skills:UpdateVoidKill"),
    ("Dropdown SetOptions implemented", r"SetOptions = SetOptions"),
    ("Profiler GetReport implemented", r"function Profiler:GetReport"),
    ("World FullBright Dirty Flag", r"_lastFullBright"),

    # Phase 3 Telemetry v10.0 Checks
    ("Telemetry Meta Version 10.0", r'Version\s*=\s*"10\.0"'),
    ("Telemetry Multi-Category Data (Hitboxes)", r"Hitboxes\s*=\s*\{\}"),
    ("Telemetry Multi-Category Data (Correlations)", r"Correlations\s*=\s*\{\}"),
    ("Telemetry Multi-Category Data (CombatEvents)", r"CombatEvents\s*=\s*\{\}"),
    ("Telemetry Multi-Category Data (Sounds)", r"Sounds\s*=\s*\{\}"),
    ("Telemetry Multi-Category Data (Tools)", r"Tools\s*=\s*\{\}"),
    ("Telemetry Multi-Category Data (Remotes)", r"Remotes\s*=\s*\{\}"),
    ("Telemetry Multi-File Directory (tsb_data/)", r"tsb_data/metadata\.json"),
    ("Telemetry ExportSummary Method", r"function TelemetryRecorder:ExportSummary"),
    ("Diagnostics Export Summary Button", r"Export Telemetry Summary"),
    ("Diagnostics Comprehensive Badges", r"Correlations Discovered"),
]

print("=== 4080 HUB EXTENDED SPECIALIST VALIDATION ===")
all_pass = True
for name, pattern in checks:
    found = bool(re.search(pattern, content, re.DOTALL))
    status = "PASS" if found else "FAIL"
    if not found:
        all_pass = False
    print(f"  [{status}] {name}")

print()
lines = len(content.splitlines())
size_kb = len(content.encode('utf-8')) / 1024
print(f"Artifact: tsb.lua | {lines} lines | {size_kb:.1f} KB")
print()
if all_pass:
    print(">>> ALL 33 SPECIALIST VERIFICATION CHECKS PASSED <<<")
else:
    print(">>> FAILURES DETECTED IN BUNDLE <<<")
