---@class blink-cmp-tmux.Opts
---@field panes? 'window' | 'session' | 'all'
---@field capture_history? boolean
---@field triggered_only? boolean
---@field trigger_chars? string[]
---@field min_update_period? integer Seconds between two reads of the panes
---@field item_lifetime? integer Seconds a word stays once its pane no longer shows it
---@field timeout? integer Milliseconds a tmux command may take
---@field max_bytes? integer Bytes read of one pane at most

---@type blink-cmp-tmux.Opts
local default_opts = {
	panes = "window",
	capture_history = false,
	triggered_only = false,
	trigger_chars = { "." },
	min_update_period = 5,
	item_lifetime = 60,
	timeout = 2000,
	max_bytes = 1024 * 1024,
}

---@module "blink.cmp"
---@class blink.cmp.tmuxSource: blink.cmp.Source
---@field opts blink-cmp-tmux.Opts
---@field items table<string, integer> Word to the `os.time()` it is dropped at
---@field last_update integer `os.time()` the last read of the panes started
---@field updating boolean A read of the panes is running
---@field waiting fun()[] Called once the read under way is done
local tmux = {}

---@param opts blink-cmp-tmux.Opts
---@return blink.cmp.tmuxSource
function tmux.new(opts)
	local self = setmetatable({}, { __index = tmux })

	self.opts = vim.tbl_deep_extend("force", default_opts, opts or {})
	self.items = {}
	self.last_update = 0
	self.updating = false
	self.waiting = {}

	return self
end

--- Inside a tmux server that is still running: `$TMUX` outlives the server
--- in shells started from it, and then every read would fail
---@return boolean
function tmux:enabled()
	local env = os.getenv("TMUX")
	if env == nil or vim.fn.executable("tmux") == 0 then
		return false
	end
	-- `$TMUX` is `<socket>,<pid>,<session>`
	local stat = vim.uv.fs_stat(env:match("^([^,]+)") or "")
	return stat ~= nil and stat.type == "socket"
end

---@return string[]
function tmux:get_trigger_characters()
	return self.opts.trigger_chars
end

---@param word string
---@param context blink.cmp.Context
---@return lsp.CompletionItem
function tmux:make_item(word, context)
	---@type lsp.CompletionItem
	local item = {
		label = word,
		kind = require("blink.cmp.types").CompletionItemKind.Text,
		insertText = word,
	}

	if self.opts.triggered_only then
		item.textEdit = {
			newText = word,
			range = {
				start = { line = context.cursor[1] - 1, character = context.bounds.start_col - 2 },
				["end"] = { line = context.cursor[1] - 1, character = context.cursor[2] },
			},
		}
	end

	return item
end

--- Run `cmd` in the background, and hand `on_done` its output on the main
--- loop, or nil when it failed; output past `max_bytes` stops the command,
--- and what came before is kept
---@param cmd string[]
---@param on_done fun(stdout: string?)
function tmux:run(cmd, on_done)
	local max = self.opts.max_bytes
	local chunks, size, cut, answered = {}, 0, false, false
	---@type vim.SystemObj?
	local process
	---@param stdout string?
	local function answer(stdout)
		if answered then
			return
		end
		answered = true
		vim.schedule(function()
			on_done(stdout)
		end)
	end
	local ok, started = pcall(vim.system, cmd, {
		text = true,
		timeout = self.opts.timeout,
		stdout = function(_, data)
			if not data or cut then
				return
			end
			size = size + #data
			if size > max then
				cut = true
				data = data:sub(1, #data - (size - max))
				if process then
					pcall(process.kill, process, "sigterm")
				end
			end
			table.insert(chunks, data)
		end,
	}, function(result)
		answer((cut or result.code == 0) and table.concat(chunks) or nil)
	end)
	if not ok then
		return answer(nil)
	end
	process = started
	-- The exit is only reported once the output closes, and something the
	-- command started can hold it open past the deadline: give up on it then
	local guard = assert(vim.uv.new_timer())
	guard:start(self.opts.timeout + 1000, 0, function()
		guard:close()
		if not answered then
			pcall(started.kill, started, "sigkill")
			answer(nil)
		end
	end)
end

---@param pane_id string
---@param on_done fun(content: string)
function tmux:get_pane_content(pane_id, on_done)
	local cmd = { "tmux", "capture-pane", "-p", "-t", pane_id, "-J" }

	if self.opts.capture_history then
		table.insert(cmd, "-S-")
	end

	self:run(cmd, function(stdout)
		on_done(stdout or "")
	end)
end

--- Hand `on_done` the ids of the panes `opts.panes` asks for, this one left
--- out
---@param on_done fun(ids: string[])
function tmux:get_pane_ids(on_done)
	local cmd = { "tmux", "list-panes", "-F", "#{pane_id}" }

	if self.opts.panes == "all" then
		table.insert(cmd, "-a")
	elseif self.opts.panes == "session" then
		table.insert(cmd, "-s")
	end
	-- This pane: its words come from the `buffer` source
	local current = os.getenv("TMUX_PANE")
	self:run(cmd, function(stdout)
		local ids = {}
		for id in string.gmatch(stdout or "", "%%%d+") do
			if current ~= id then
				table.insert(ids, id)
			end
		end
		on_done(ids)
	end)
end

--- The words of `content`
---@param content string
---@param words? table<string, true> Added to, when given
---@return table<string, true>
function tmux.get_words(content, words)
	words = words or {}
	-- match not only full words, but urls, paths, etc.
	for word in string.gmatch(content, "[%w%d_:/.%-~]+") do
		words[word] = true

		-- but also isolate the words from the result
		for sub_word in string.gmatch(word, "[%w%d]+") do
			words[sub_word] = true
		end
	end
	return words
end

--- Read the panes in the background, one after the other, once
--- `min_update_period` has passed since the last read; `on_done` is called
--- when the read under way, this one or an earlier one, is done
---@param on_done? fun()
---@param force? boolean Read even before `min_update_period` has passed
function tmux:refresh(on_done, force)
	if self.updating then
		if on_done then
			table.insert(self.waiting, on_done)
		end
		return
	end
	local now = os.time()
	if not force and now - self.last_update < self.opts.min_update_period then
		if on_done then
			on_done()
		end
		return
	end
	self.updating, self.last_update = true, now
	if on_done then
		table.insert(self.waiting, on_done)
	end

	local found = {}
	local function finish()
		local time = os.time()
		local expires = time + self.opts.item_lifetime
		for word in pairs(found) do
			self.items[word] = expires
		end
		for word, at in pairs(self.items) do
			if at < time then
				self.items[word] = nil
			end
		end
		self.updating = false
		local waiting = self.waiting
		self.waiting = {}
		for _, callback in ipairs(waiting) do
			callback()
		end
	end

	self:get_pane_ids(function(ids)
		local index = 0
		local function next_pane()
			index = index + 1
			if index > #ids then
				return finish()
			end
			self:get_pane_content(ids[index], function(content)
				tmux.get_words(content, found)
				next_pane()
			end)
		end
		next_pane()
	end)
end

---@param context blink.cmp.Context
---@return boolean
function tmux:is_triggered(context)
	if not self.opts.triggered_only then
		return true
	end
	local char = context.line:sub(context.bounds.start_col - 1, context.bounds.start_col - 1)

	return vim.list_contains(self:get_trigger_characters(), char)
end

---@param context blink.cmp.Context
---@return lsp.CompletionItem[]
function tmux:get_completion_items(context)
	if not self:is_triggered(context) then
		return {}
	end

	local words = vim.tbl_keys(self.items)
	table.sort(words)
	return vim.iter(words)
		:map(function(word)
			return self:make_item(word, context)
		end)
		:totable()
end

--- Answered from the words kept, at once; the panes are read again in the
--- background when they are due, and only the very first completion waits
--- for that read
---@param context blink.cmp.Context
---@param callback fun(items: blink.cmp.CompletionResponse)
function tmux:get_completions(context, callback)
	local function respond()
		callback({
			items = self:get_completion_items(context),
			is_incomplete_backward = false,
			is_incomplete_forward = false,
		})
	end

	if self.last_update == 0 then
		return self:refresh(respond)
	end
	self:refresh()
	respond()
end

return tmux
