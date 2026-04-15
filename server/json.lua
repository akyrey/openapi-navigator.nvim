-- Pure-Lua JSON encoder / decoder.
-- Based on rxi/json.lua (MIT licence) — vendored to avoid external dependencies.
-- https://github.com/rxi/json.lua

local json = {}

-- ── Encode ────────────────────────────────────────────────────────────────────

local encode

local escape_char_map = {
	["\\" ] = "\\\\",
	["\"" ] = "\\\"",
	["\b" ] = "\\b",
	["\f" ] = "\\f",
	["\n" ] = "\\n",
	["\r" ] = "\\r",
	["\t" ] = "\\t",
}

local function escape_char(c)
	return escape_char_map[c]
		or string.format("\\u%04x", c:byte())
end

local function encode_nil()
	return "null"
end

local function encode_table(val, stack)
	local res = {}
	stack = stack or {}

	-- Detect circular references
	if stack[val] then
		error("circular reference")
	end
	stack[val] = true

	-- Detect array vs object
	local n = 0
	for _ in pairs(val) do
		n = n + 1
	end

	local is_array = (n == 0) or (val[1] ~= nil)
	if is_array then
		-- Verify it's a proper sequence
		local len = #val
		if n ~= len then
			is_array = false
		end
	end

	if is_array then
		for i = 1, #val do
			res[i] = encode(val[i], stack)
		end
		stack[val] = nil
		return "[" .. table.concat(res, ",") .. "]"
	else
		local i = 0
		for k, v in pairs(val) do
			if type(k) ~= "string" then
				error("non-string key in table: " .. tostring(k))
			end
			i = i + 1
			res[i] = encode(k, stack) .. ":" .. encode(v, stack)
		end
		stack[val] = nil
		return "{" .. table.concat(res, ",") .. "}"
	end
end

local encode_type_map = {
	["nil"]     = encode_nil,
	["boolean"] = tostring,
	["number"]  = function(v)
		if v ~= v then return "null" end          -- NaN
		if v == math.huge or v == -math.huge then return "null" end
		-- Integers as integers, floats with decimal
		if v == math.floor(v) and math.abs(v) < 2^53 then
			return string.format("%d", v)
		end
		return string.format("%.14g", v)
	end,
	["string"]  = function(v)
		return '"' .. v:gsub('[%z\1-\31\\"]', escape_char) .. '"'
	end,
	["table"]   = encode_table,
}

encode = function(val, stack)
	local t = type(val)
	local f = encode_type_map[t]
	if f then
		return f(val, stack)
	end
	error("unsupported type: " .. t)
end

function json.encode(val)
	return encode(val)
end

-- ── Decode ────────────────────────────────────────────────────────────────────

local decode

local function create_set(...)
	local res = {}
	for _, v in ipairs({ ... }) do
		res[v] = true
	end
	return res
end

local space_chars   = create_set(" ", "\t", "\r", "\n")
local delim_chars   = create_set(" ", "\t", "\r", "\n", "]", "}", ",")
local escape_chars  = create_set("\\", "/", '"', "b", "f", "n", "r", "t", "u")
-- null decodes to Lua nil; keep a separate ordered list because pairs() skips nil values.
local literals      = { ["true"] = true, ["false"] = false, ["null"] = nil }
local literal_names = { "true", "false", "null" }

local function next_char(str, idx, set, negate)
	for i = idx, #str do
		if set[str:sub(i, i)] ~= negate then
			return i
		end
	end
	return #str + 1
end

local function decode_error(str, idx, msg)
	local line = 1
	local col  = 1
	for i = 1, idx - 1 do
		col = col + 1
		if str:sub(i, i) == "\n" then
			line = line + 1
			col  = 1
		end
	end
	error(string.format("%s at line %d col %d", msg, line, col))
end

-- Use arithmetic instead of Lua 5.3 bitwise operators for LuaJIT (5.1) compat.
local function codepoint_to_utf8(n)
	if n < 0x80 then
		return string.char(n)
	elseif n < 0x800 then
		return string.char(
			0xC0 + math.floor(n / 64),
			0x80 + (n % 64)
		)
	elseif n < 0x10000 then
		return string.char(
			0xE0 + math.floor(n / 4096),
			0x80 + math.floor(n / 64) % 64,
			0x80 + (n % 64)
		)
	elseif n < 0x110000 then
		return string.char(
			0xF0 + math.floor(n / 262144),
			0x80 + math.floor(n / 4096) % 64,
			0x80 + math.floor(n / 64) % 64,
			0x80 + (n % 64)
		)
	end
	error("invalid unicode codepoint: " .. n)
end

local function parse_unicode_escape(str, i)
	local n = tonumber(str:sub(i + 1, i + 4), 16)
	if not n then
		decode_error(str, i, "invalid unicode escape")
	end
	i = i + 5

	-- Handle UTF-16 surrogate pairs
	if n >= 0xD800 and n <= 0xDBFF then
		if str:sub(i, i + 1) ~= "\\u" then
			decode_error(str, i, "expected surrogate pair")
		end
		local n2 = tonumber(str:sub(i + 2, i + 5), 16)
		if not n2 or n2 < 0xDC00 or n2 > 0xDFFF then
			decode_error(str, i, "invalid surrogate pair")
		end
		n = 0x10000 + (n - 0xD800) * 0x400 + (n2 - 0xDC00)
		i = i + 6
	end

	return codepoint_to_utf8(n), i
end

local escape_map = {
	["\\"] = "\\",
	["/"]  = "/",
	['"']  = '"',
	["b"]  = "\b",
	["f"]  = "\f",
	["n"]  = "\n",
	["r"]  = "\r",
	["t"]  = "\t",
}

local function parse_string(str, i)
	local result = {}
	i = i + 1  -- skip opening quote
	while true do
		local j = i
		while j <= #str do
			local c = str:sub(j, j)
			if c == '"' then
				break
			elseif c == "\\" then
				break
			elseif c:byte() < 32 then
				decode_error(str, j, "control character in string")
			end
			j = j + 1
		end
		if j > #str then
			decode_error(str, i, "unterminated string")
		end
		table.insert(result, str:sub(i, j - 1))
		local c = str:sub(j, j)
		if c == '"' then
			return table.concat(result), j + 1
		end
		-- escape sequence
		local esc = str:sub(j + 1, j + 1)
		if esc == "u" then
			local utf, ni = parse_unicode_escape(str, j + 1)
			table.insert(result, utf)
			i = ni
		else
			local mapped = escape_map[esc]
			if not mapped then
				decode_error(str, j, "invalid escape: \\" .. esc)
			end
			table.insert(result, mapped)
			i = j + 2
		end
	end
end

local function parse_number(str, i)
	local j = next_char(str, i, delim_chars)
	local s = str:sub(i, j - 1)
	local n = tonumber(s)
	if not n then
		decode_error(str, i, "invalid number: " .. s)
	end
	return n, j
end

local function parse_literal(str, i)
	for _, name in ipairs(literal_names) do
		if str:sub(i, i + #name - 1) == name then
			return literals[name], i + #name
		end
	end
	decode_error(str, i, "invalid literal")
end

local function parse_array(str, i)
	local result = {}
	local n = 1
	i = i + 1  -- skip '['
	while true do
		local x
		i = next_char(str, i, space_chars, true)
		if str:sub(i, i) == "]" then
			return result, i + 1
		end
		x, i = decode(str, i)
		result[n] = x
		n = n + 1
		i = next_char(str, i, space_chars, true)
		local c = str:sub(i, i)
		if c == "]" then
			return result, i + 1
		end
		if c ~= "," then
			decode_error(str, i, "expected ',' or ']'")
		end
		i = i + 1
	end
end

local function parse_object(str, i)
	local result = {}
	i = i + 1  -- skip '{'
	while true do
		local key, val
		i = next_char(str, i, space_chars, true)
		if str:sub(i, i) == "}" then
			return result, i + 1
		end
		if str:sub(i, i) ~= '"' then
			decode_error(str, i, "expected string key")
		end
		key, i = parse_string(str, i)
		i = next_char(str, i, space_chars, true)
		if str:sub(i, i) ~= ":" then
			decode_error(str, i, "expected ':'")
		end
		i = next_char(str, i + 1, space_chars, true)
		val, i = decode(str, i)
		result[key] = val
		i = next_char(str, i, space_chars, true)
		local c = str:sub(i, i)
		if c == "}" then
			return result, i + 1
		end
		if c ~= "," then
			decode_error(str, i, "expected ',' or '}'")
		end
		i = i + 1
	end
end

local char_func_map = {
	['"'] = parse_string,
	["0"] = parse_number, ["1"] = parse_number, ["2"] = parse_number,
	["3"] = parse_number, ["4"] = parse_number, ["5"] = parse_number,
	["6"] = parse_number, ["7"] = parse_number, ["8"] = parse_number,
	["9"] = parse_number, ["-"] = parse_number,
	["t"] = parse_literal, ["f"] = parse_literal, ["n"] = parse_literal,
	["["] = parse_array,
	["{"] = parse_object,
}

decode = function(str, i)
	local c = str:sub(i, i)
	local f = char_func_map[c]
	if f then
		return f(str, i)
	end
	decode_error(str, i, "unexpected character: " .. c)
end

function json.decode(str)
	if type(str) ~= "string" then
		error("expected string, got " .. type(str))
	end
	local i = next_char(str, 1, space_chars, true)
	local x, j = decode(str, i)
	-- Trailing whitespace is fine; anything else is an error
	local k = next_char(str, j, space_chars, true)
	if k <= #str then
		decode_error(str, k, "trailing garbage")
	end
	return x
end

-- ── json.null sentinel ───────────────────────────────────────────────────────

-- Use a sentinel userdata-like table to represent explicit JSON null vs Lua nil.
-- In LSP responses, fields set to json.null encode as "null" in JSON.
json.null = setmetatable({}, {
	__tostring = function() return "null" end,
	__newindex = function() error("json.null is read-only") end,
})

-- Patch encode to handle the sentinel
local _orig_encode_table = encode_type_map["table"]
encode_type_map["table"] = function(val, stack)
	if val == json.null then
		return "null"
	end
	return _orig_encode_table(val, stack)
end

return json
