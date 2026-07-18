import subprocess
import os
import sys

tests = {
    "test1_math_logical.lua": """
local a = 10
local b = 20
local c = a + b * 3
local d = (c >> 2) | 5
local e = ~d & 15
print("Math/Logical Result:", c, d, e)
""",

    "test2_closures.lua": """
local function make_counter()
    local count = 0
    return function()
        count = count + 1
        return count
    end
end
local c1 = make_counter()
print("Counter 1:", c1())
print("Counter 2:", c1())
print("Counter 3:", c1())
""",

    "test3_oop.lua": """
local Account = {}
Account.__index = Account

function Account:new(balance)
    local obj = setmetatable({}, self)
    obj.balance = balance or 0
    return obj
end

function Account:deposit(amount)
    self.balance = self.balance + amount
    return self.balance
end

local acc = Account:new(100)
print("Initial Balance:", acc.balance)
print("After Deposit:", acc:deposit(50))
""",

    "test4_coroutines.lua": """
local co = coroutine.create(function()
    print("Co-routine yielded:", coroutine.yield("yield_val"))
    return "final_val"
end)
local _, r1 = coroutine.resume(co)
print("R1:", r1)
local _, r2 = coroutine.resume(co, "resume_val")
print("R2:", r2)
""",

    "test5_pcall.lua": """
local function risky()
    error("failed safely")
end
local ok, err = pcall(risky)
print("pcall ok:", ok)
print("pcall err:", err:find("failed safely") ~= nil)
""",

    "test6_nested_vm.lua": """
-- This will compile functions into VM_B via STORM instructions
local function outer()
    local x = 42
    local function inner()
        return x + 8
    end
    return inner()
end
print("Nested VM result:", outer())
""",

    "test7_antidebug.lua": """
-- @antiDebug false
print("AntiDebug disabled, ran successfully!")
"""
}

def run_cmd(cmd):
    p = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out, err = p.communicate()
    return out.decode('utf-8', errors='ignore'), err.decode('utf-8', errors='ignore'), p.returncode

print("=== STARTING INTEGRATED TEST SUITE ===")
all_pass = True

for name, code in sorted(tests.items()):
    print(f"\\nRunning test: {name}")
    # Write original code
    with open(name, "w") as f:
        f.write(code.strip())

    # Run original code
    orig_out, orig_err, orig_code = run_cmd(f"lua {name}")
    if orig_code != 0:
        print(f"  [ERROR] Original code failed to run! Err: {orig_err}")
        all_pass = False
        continue

    # Obfuscate
    obf_name = name.replace(".lua", "_obf.lua")
    obf_out, obf_err, obf_code = run_cmd(f"lua obfuscator.lua {name} {obf_name}")
    if obf_code != 0:
        print(f"  [ERROR] Obfuscation failed! Err: {obf_err}")
        all_pass = False
        continue

    # Run obfuscated code
    run_out, run_err, run_code = run_cmd(f"lua {obf_name}")
    if run_code != 0:
        print(f"  [ERROR] Obfuscated code failed to run! Err: {run_err}")
        all_pass = False
        continue

    # Compare output
    if orig_out == run_out:
        print(f"  [PASS] Output matches perfectly!")
        print(f"  Output: {run_out.strip()}")
    else:
        print(f"  [FAIL] Output mismatch!")
        print(f"  Original output:\\n{orig_out}")
        print(f"  Obfuscated output:\\n{run_out}")
        all_pass = False

    # Clean up
    if os.path.exists(name): os.remove(name)
    if os.path.exists(obf_name): os.remove(obf_name)

if all_pass:
    print("\\n=== ALL 7 TESTS PASSED SUCCESSFULLY! ===")
    sys.exit(0)
else:
    print("\\n=== TEST SUITE FAILED ===")
    sys.exit(1)
