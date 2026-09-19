-- 接続されている peripheral と利用可能なメソッドを一覧表示する。
-- 実行: scan

local names = peripheral.getNames()
table.sort(names)

if #names == 0 then
  print("peripheral が見つかりません。Wired Modem とケーブルを確認してください。")
  return
end

for _, name in ipairs(names) do
  local types = { peripheral.getType(name) }
  local methods = peripheral.getMethods(name) or {}
  table.sort(methods)

  print("----------------------------------------")
  print(name)
  print("  type: " .. table.concat(types, ", "))
  print("  methods: " .. (#methods > 0 and table.concat(methods, ", ") or "(none)"))
end
