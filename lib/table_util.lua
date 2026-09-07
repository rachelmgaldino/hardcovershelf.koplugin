-- Trimmed copy of hardcoverapp.koplugin's TableUtil (MIT, see
-- ../THIRD_PARTY_NOTICES.md) -- only the two functions this plugin uses.

local TableUtil = {}

function TableUtil.dig(t, ...)
  local result = t

  for _, k in ipairs({ ... }) do
    result = result[k]
    if result == nil then
      return nil
    end
  end

  return result
end

function TableUtil.map(t, cb)
  local result = {}
  for i, v in ipairs(t) do
    result[i] = cb(v, i)
  end
  return result
end

return TableUtil
