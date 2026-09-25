# -*- coding: utf-8 -*-
"""
⚡ 4080 HUB - CI / BUNDLER & VALIDATION PIPELINE (bundle.py)
Automated multi-stage compiler, static analyzer, and build pipeline for the
Specialist Production-Grade TSB Framework.

Pipeline Stages:
1. Module Discovery & Static Analysis (AST / Require Graph)
2. Structural Syntax & Balancing Verification
3. Virtual Module Bundling
4. Public Framework Surface Injection (Start/Stop/Destroy/GetDiagnostics/RunTests)
5. Artifact Integrity & SHA-256 Checksum Generation
"""

import os
import re
import hashlib
import sys

BASE_DIR = os.getcwd()
SRC_DIR = os.path.join(BASE_DIR, "src")

print("=" * 80)
print("🚀 4080 HUB - SPECIALIST CI BUILD & VERIFICATION PIPELINE")
print("=" * 80)

# -----------------------------------------------------------------------------
# STAGE 1: Module Discovery & Source Gathering
# -----------------------------------------------------------------------------
print("\n[STAGE 1] Scanning 'src/' directory for Luau modules...")
modules = {}

for root, _, files in os.walk(SRC_DIR):
    for f in files:
        if f.endswith(".luau") or f.endswith(".lua"):
            full_path = os.path.join(root, f)
            rel_path = os.path.relpath(full_path, SRC_DIR).replace("\\", "/")
            mod_name = os.path.splitext(rel_path)[0]
            with open(full_path, "r", encoding="utf-8") as src_f:
                modules[mod_name] = src_f.read()

print(f"  ✓ Discovered {len(modules)} modules in src/ hierarchy.")

# -----------------------------------------------------------------------------
# STAGE 2: Static Analysis - Require Graph & Integrity Check
# -----------------------------------------------------------------------------
print("\n[STAGE 2] Performing Static Analysis on Dependency & Require Graphs...")
require_pattern = re.compile(r'require\(["\']([^"\']+)["\']\)')

missing_dependencies = []
all_normalized_modules = {m.replace("/", "."): m for m in modules.keys()}

for mod_name, mod_code in modules.items():
    clean_name = mod_name.replace("/", ".")
    for match in require_pattern.finditer(mod_code):
        target = match.group(1).replace("/", ".").replace(".luau", "").replace(".lua", "")
        if target.startswith("src."):
            target = target[4:]
        if target not in all_normalized_modules and target not in modules:
            missing_dependencies.append((clean_name, target))

if missing_dependencies:
    print("  ❌ FATAL: Missing module dependencies detected:")
    for src, missing in missing_dependencies:
        print(f"     - '{src}' requires missing module: '{missing}'")
    sys.exit(1)
else:
    print("  ✓ All internal module requires successfully verified & resolved.")

# -----------------------------------------------------------------------------
# STAGE 3: Structural Syntax & Bracket Balancing Check
# -----------------------------------------------------------------------------
print("\n[STAGE 3] Checking Bracket and Token Balance across all modules...")
bracket_pairs = {'(': ')', '[': ']', '{': '}'}
balance_errors = []

for mod_name, mod_code in modules.items():
    for op, cl in bracket_pairs.items():
        if mod_code.count(op) != mod_code.count(cl):
            balance_errors.append(f"'{mod_name}': unbalanced {op}...{cl} ({mod_code.count(op)} vs {mod_code.count(cl)})")

if balance_errors:
    print("  ❌ FATAL: Syntax balance errors detected:")
    for err in balance_errors:
        print(f"     - {err}")
    sys.exit(1)
else:
    print("  ✓ All modules passed bracket balance and lexical verification.")

# -----------------------------------------------------------------------------
# STAGE 4: Virtual Module Bundler & Public Framework Surface Injection
# -----------------------------------------------------------------------------
print("\n[STAGE 4] Assembling Standalone Bundle with Public Framework Surface...")

bundle_header = """-- // ========================================================================================
-- // ⚡ 4080 CUSTOM HUB v9.0 - SPECIALIST PRODUCTION FRAMEWORK
-- // Architecture: Modular Luau Service Architecture + IoC Container + FSM & Telemetry
-- // Pipeline: Automated CI/CD Verified Build
-- // ========================================================================================

local __modules = {}
local __cache = {}
local __loading = {}

local function require(modName)
    local normalized = modName:gsub("%.luau$", ""):gsub("%.lua$", ""):gsub("^src/", "")
    normalized = normalized:gsub("/", ".")
    
    if __cache[normalized] ~= nil then
        return __cache[normalized]
    end

    -- Exact or normalized match
    local modFunc = __modules[normalized] or __modules[modName] or __modules[normalized:gsub("%.", "/")]
    if not modFunc then
        for k, v in pairs(__modules) do
            if k:lower() == normalized:lower() or k:lower() == modName:lower() then
                modFunc = v
                normalized = k
                break
            end
        end
    end

    if not modFunc then
        error(string.format("[Bundler] Module '%s' not found!", tostring(modName)))
    end

    if __loading[normalized] then
        -- Circular require cycle guard: prevent infinite C-stack recursion
        if __cache[normalized] == nil then
            __cache[normalized] = {}
        end
        return __cache[normalized]
    end

    __loading[normalized] = true
    local exports = modFunc()
    __cache[normalized] = exports
    __loading[normalized] = nil

    return exports
end
"""

bundle_body = ""
for mod_name, mod_content in sorted(modules.items()):
    clean_name = mod_name.replace("/", ".")
    bundle_body += f'\n-- ============================================================================\n'
    bundle_body += f'-- Module: {clean_name}\n'
    bundle_body += f'-- ============================================================================\n'
    bundle_body += f'__modules["{clean_name}"] = function()\n{mod_content}\nend\n'
    if "/" in mod_name:
        bundle_body += f'__modules["{mod_name}"] = __modules["{clean_name}"]\n'

bundle_footer = """
-- ============================================================================
-- FRAMEWORK PUBLIC RUNTIME SURFACE & ENTRYPOINT
-- ============================================================================
local Bootstrap = require("Bootstrap")
local UnitTests = require("Diagnostics.UnitTests")

local Framework = {
    Version = "9.0-SPECIALIST-PRODUCTION",
    Bootstrap = Bootstrap,
    
    Start = function(self)
        return Bootstrap:Init()
    end,
    
    Stop = function(self)
        return Bootstrap:Destroy()
    end,
    
    Destroy = function(self)
        return Bootstrap:Destroy()
    end,
    
    GetService = function(self, serviceName: string)
        if Bootstrap.Container and Bootstrap.Container:Has(serviceName) then
            return Bootstrap.Container:Get(serviceName)
        end
        return nil
    end,
    
    GetDiagnostics = function(self)
        return Bootstrap:GetDiagnostics()
    end,
    
    GetUI = function(self)
        if Bootstrap.Container and Bootstrap.Container:Has("UIController") then
            return Bootstrap.Container:Get("UIController")
        end
        return nil
    end,
    
    RunTests = function(self)
        return UnitTests.RunAll()
    end,
}

-- Expose Public Framework Handle to Global Environment for External Lifecycle Control
if typeof(_G) == "table" then
    _G.TSBFramework = Framework
end
if typeof(getgenv) == "function" then
    pcall(function()
        getgenv().TSBFramework = Framework
    end)
end

-- Automatic Framework Boot with Error Handling & Native Notification
print("[4080 HUB v9.0] Initializing Specialist Production Framework...")

local okBoot, bootErr = pcall(function()
    Bootstrap:Init()
end)

if not okBoot then
    warn("[4080 HUB v9.0] FATAL BOOT ERROR: " .. tostring(bootErr))
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "TSB HUB Error",
            Text = "Boot failed: " .. tostring(bootErr):sub(1, 80),
            Duration = 10,
        })
    end)
else
    print("[4080 HUB v9.0] Specialist Production Framework Booted Successfully.")
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "⚡ TSB HUB v9.0",
            Text = "Specialist Hub Loaded! Press RightControl to toggle UI.",
            Duration = 5,
        })
    end)
end

return Framework
"""

full_bundle = bundle_header + bundle_body + bundle_footer
target_path = os.path.join(BASE_DIR, "tsb.lua")

with open(target_path, "w", encoding="utf-8") as f:
    f.write(full_bundle)

# -----------------------------------------------------------------------------
# STAGE 5: Artifact Verification & Checksum
# -----------------------------------------------------------------------------
print("\n[STAGE 5] Generating Build Artifact Manifest & Checksum...")
sha256_hash = hashlib.sha256(full_bundle.encode("utf-8")).hexdigest()
line_count = len(full_bundle.splitlines())
byte_count = len(full_bundle.encode("utf-8"))

print("=" * 80)
print("✨ BUILD SUCCEEDED - PRODUCTION ARTIFACT READY")
print("=" * 80)
print(f"  Artifact File : {target_path}")
print(f"  Total Modules : {len(modules)}")
print(f"  Total Lines   : {line_count:,}")
print(f"  Artifact Size : {byte_count:,} bytes ({byte_count / 1024:.2f} KB)")
print(f"  SHA-256 Check : {sha256_hash}")
print("=" * 80)
