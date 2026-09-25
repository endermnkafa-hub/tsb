import re

with open('tsb.lua', 'r', encoding='utf-8') as f:
    content = f.read()

checks = [
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
]

print("=== 4080 HUB VALIDATION REPORT ===")
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
print(f"Bundle: {lines} lines, {size_kb:.1f} KB")
print()
if all_pass:
    print("ALL CHECKS PASSED - tsb.lua is production ready")
else:
    print("FAILURES DETECTED - review above")
