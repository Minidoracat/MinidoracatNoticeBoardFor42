-- smoke_harness.lua — 家族統一的行為閘門入口（在 repo 根目錄執行：lua scripts/smoke_harness.lua）
-- 本 repo 的行為測試分兩支（test_mdparser.lua 純模組、test_nbpanel.lua 載原版 ISUI 實跑），
-- 保留各自檔名（原始碼與 docs 大量引用）；本檔只依序執行並匯總退出碼。
-- verify_mod.py 第 13 項仍分別跑兩支並認 SKIP 字樣，不經本檔。
local tests = { "scripts/test_mdparser.lua", "scripts/test_nbpanel.lua" }
local failed = 0
for _, t in ipairs(tests) do
    print(("== %s =="):format(t))
    local ok, how, code = os.execute(("lua %s"):format(t))
    -- Lua 5.1 回傳數字碼；5.2+ 回傳 (ok, "exit", code)
    local rc = (type(ok) == "number") and ok or ((how == "exit") and code or (ok and 0 or 1))
    if rc ~= 0 then
        failed = failed + 1
        print(("FAIL %s (exit %d)"):format(t, rc))
    end
end
if failed > 0 then
    print(("smoke_harness: %d 支測試失敗"):format(failed))
    os.exit(1)
end
print("smoke_harness: 全部通過（含 SKIP 的測試以其自身輸出為準）")
