--[[
opencalc - an open source calcualtor

Copyright (C) 2011  Richard Titmuss <richard@opencalc.me>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License along
with this program in the file COPYING; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
--]]

require("parser/toy")
local Cell = require("cell")

module(..., package.seeall)


Sheet = {}


-- convert cell address (eg Z99) into index (eg 26, 99)
function Sheet:cellIndex(addr)
	local rowstr, colstr = string.match(addr, "(%u+)(%d+)")

	if colstr == nil then
		error("Invalid cell address")
	end

	local row = 0
	for i,c in ipairs({ string.byte(rowstr, 1, #rowstr) }) do
		row = (row * 26) + (c -64)
	end

	return row, tonumber(colstr)
end


-- convert cell index (eg 26, 99) into address (eg Z99)
function Sheet:cellAddr(row, col)
	local rowstr = ""
	while (row > 26) do
		rowstr = rowstr .. string.char((row % 26) + 64)
		row = math.floor(row / 26)
	end
	rowstr = string.char(row + 64) .. rowstr

	return rowstr .. tostring(col)
end


function Sheet:cellRel(addr, relrow, relcol)
	local row, col = Sheet:cellIndex(addr)

	return Sheet:cellAddr(
		math.max(1, row + relrow),
		math.max(1, col + relcol))
end


function Sheet:rangeRel(addr, relrow, relcol)
	return addr .. ":" .. Sheet:cellRel(addr, relrow, relcol)
end


-- return a new spreadsheet
function Sheet:new()
	obj = {
		cells = {},

		-- cursor position
		x = 1,
		y = 1,

		max_row = 1,
		max_col = 1,

		-- recalculation flag
		set = 2,

		-- parser
		parse = parser_toy,

		-- views
		views = { { "view/basic", "Basic" } },
		view = false,

		-- preferences
		pref = { },
	}

	setmetatable(obj, self)
	self.__index = self
	return obj
end


function Sheet:propMenu()
	view_menu = self:getView():propMenu()

	local sheet_menu = {
		-- example sheet setting
		{ "Trig Mode", "trigmode", { "Deg", "Rad", "Grad" }, def = "Deg", todo = true },
		{ "Rounding", "roundingmode", { "nearest", "toward zero", "plus infinity", "minus infinity", "away from zero" }, def = "nearest", todo = true },
		{ "Precision", "precision", { "15", "20", "25" }, def = "15", todo = true },
	}

	for i, item in ipairs(sheet_menu) do
		table.insert(view_menu, item)
	end

	return view_menu
end


-- return the cursor address
function Sheet:getCursor()
	return Sheet:cellAddr(self.x, self.y)
end


-- set the cursor address
function Sheet:setCursor(addr_relrow, relcol)
	if type(addr_relrow) == "string" then
		self.x, self.y = Sheet:cellIndex(addr_relrow)
	else
		self.x = math.max(1, self.x + addr_relrow)
		self.y = math.max(1, self.y + relcol)
	end
end


-- return the sheet size, as a cell address
function Sheet:getSize()
	return Sheet:cellAddr(self.max_row, self.max_col)
end


-- create a new cell at given address, or cursor position
function Sheet:insertCell(text, addr)
	local row, col

	if addr == nil then
		row, col = self.x, self.y
	else
		row, col = Sheet:cellIndex(addr)
	end

	local rowarray = self.cells[row]
	if rowarray == nil then
		rowarray = {}
		self.cells[row] = rowarray
	end

	local val, f = self.parse(self, row, col, text)

	rowarray[col] = Cell:new(self, row, col, text, val, f)

	if row > self.max_row then
		self.max_row = row
	end
	if col > self.max_col then
		self.max_col = col
	end

	if addr == nil then
		self.y = self.y + 1
	end

	self:recalculate()
end


-- return a cell
function Sheet:getCell(addr)
	local row, col

	if addr then
		row, col = Sheet:cellIndex(addr)
	else
		row, col = self.x, self.y
	end

	local rowarray = self.cells[row]
	if rowarray == nil then
		return false
	end

	return rowarray[col] or false
end


-- return an iterator over cell range (eg A2:D4 or A2)
-- traverses range columns, then rows
function Sheet:getCellRangeByCol(range)
	local tl, br = string.match(range, "(%u+%d+):(%u+%d+)")

	if tl == nil then
		tl = range
		br = range
	end

	local tl_row, tl_col = Sheet:cellIndex(tl)
	local br_row, br_col = Sheet:cellIndex(br)
	local row_inc, col_inc = 1, 1

	if br_row < tl_row then
		row_inc = -1
	end
	if br_col < tl_col then
		col_inc = -1
	end

	local f = function()
		for i = tl_row, br_row, row_inc do
			local rowarray = self.cells[i]
			if rowarray then
				for j = tl_col, br_col, col_inc do
					coroutine.yield(rowarray[j] or false)
				end
			else
				for j = tl_col, br_col, col_inc do
					coroutine.yield(false)
				end
			end
		end
	end

	return coroutine.wrap(f)
end


function Sheet:getCellRangeByRow(range, relrow, relcol)
	local tl, br = string.match(range, "(%u+%d+):(%u+%d+)")

	if tl == nil then
		tl = range
		br = range
	end

	local tl_row, tl_col = Sheet:cellIndex(tl)
	local br_row, br_col

	if relrow then
		br_row = math.max(1, tl_row + relrow)
		br_col = math.max(1, tl_col + relcol)
	else
		br_row, br_col = Sheet:cellIndex(br)
	end

	local row_inc, col_inc = 1, 1
	if br_row < tl_row then
		row_inc = -1
	end
	if br_col < tl_col then
		col_inc = -1
	end

	local f = function()
		for j = tl_col, br_col, col_inc do
			for i = tl_row, br_row, row_inc do
				local rowarray = self.cells[i]
				if rowarray then
					coroutine.yield(rowarray[j] or false)
				else
					coroutine.yield(false)
				end
			end
		end
	end

	return coroutine.wrap(f)
end


-- force re-calculation
function Sheet:recalculate()
	-- increment the recalculation flag
	self.set = self.set + 1

	-- should we evaulate all cells here? i'm not sure that is
	-- required as the values will be calculated on demand and
	-- only a small subset of cells will be visible at one time
end


function Sheet:setProp(key, value)
	self.pref[key] = value
end


function Sheet:getProp(key, default)
	return self.pref[key] or default
end


-- add a view to the spreadsheet
function Sheet:addView(view, name)
	table.insert(self.views, { view, name or view })
end


-- return the next view
function Sheet:nextView(advance)
	for i = 1,(advance or 1) do
		local popView = table.remove(self.views, 1)
		table.insert(self.views, popView)
	end

	self.view = false

	return self.views[1][1], self.views[1][2]
end


-- return current view
function Sheet:getView()
	if not self.view then
		local module = require(self.views[1][1])
		self.view = module:new(self)
	end

	return self.view
end


-- dump sheet to stdout for debugging
function Sheet:dump()
	for cell in self:getCellRangeByCol("A1:" .. self:getSize()) do
		if cell then
			cell:dump()
		end
	end
end


-- save as csv
function Sheet:saveCsv(filename)
	local file = io.open(filename, "w")

	for i = 1,self.max_col do
		for j = 1,self.max_row do

			if self.cells[j] and self.cells[j][i] then
				local text = self.cells[j][i]:text()


				if string.find(text, '[,"]') then
					text = '"' .. string.gsub(text, '"', '""') .. '"'
				end
				file:write(text .. ",")
			else
				file:write(",")
			end
		end
		file:write("\n")
	end

	file:close()
end


-- iterator to parse csv files
local parseCsv = function(line)
	local f = function()
		local str = 1
		repeat
			if line:find('^"', str) then
				local a, c
				local i = str
				repeat
					a, i, c = line:find('"("?)', i+1)
				until c ~= '"'
				if not i then
					error('unmatched "')
				end
				local f = line:sub(str + 1, i - 1)
				coroutine.yield(f:gsub('""', '"'))
				str = line:find(',', i) + 1
			else
				local next = line:find(',', str)
				coroutine.yield(line:sub(str, next - 1))
				str = next + 1
			end
		until str > line:len()
	end

	return coroutine.wrap(f)
end


-- load from csv
function Sheet:loadCsv(filename)
	local file = io.open(filename, "r")

	local i = 1
	for line in file:lines() do
		local j = 1
		for text in parseCsv(line) do
			if text ~= "" then
				self:insertCell(text, Sheet:cellAddr(j, i))
			end
			j = j + 1
		end
		i = i + 1
	end

	file:close()
end


return Sheet
