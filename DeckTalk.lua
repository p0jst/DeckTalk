-- DeckTalk: one-tap chat for Steam Deck / controller players
local ADDON = ...

---------------------------------------------------------------------------
-- Defaults
---------------------------------------------------------------------------
local NUM_PHRASES = 8
local DEFAULTS = {
	phrases = {
		{ label = "Hi!",        text = "Hi!" },
		{ label = "Thanks!",    text = "Thanks for the help!" },
		{ label = "Sorry",      text = "Sorry!" },
		{ label = "Ready",      text = "Ready." },
		{ label = "One sec",    text = "One moment please." },
		{ label = "BRB",        text = "BRB, back in a few minutes." },
		{ label = "Group up?",  text = "Want to group up for %q?" },
		{ label = "GG / Bye",   text = "Thanks for the group, have a good one!" },
	},
	note       = "I'm playing on a Steam Deck and typing is slow - sorry if I don't reply much!",
	lfgFormat  = "LFG %q - anyone want to group up?",
	lfgChannel = "LookingForGroup",
	autoIntro  = true,   -- post note to group chat when joining a group
	autoReply  = true,   -- whisper note back to people who whisper you
	shown      = true,
	scale      = 1,
}

local DB
local lastWhisperer
local replied = {}            -- [sender] = GetTime()
local REPLY_COOLDOWN = 600    -- seconds per sender

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function Print(msg)
	print("|cff33ccffDeckTalk|r: " .. tostring(msg))
end

local function CopyDefaults(src, dst)
	for k, v in pairs(src) do
		if type(v) == "table" then
			if type(dst[k]) ~= "table" then dst[k] = {} end
			CopyDefaults(v, dst[k])
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
	return dst
end

local SendChat = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage

local function GetTrackedQuestID()
	local id = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID()
	if (not id or id == 0) and C_QuestLog.GetQuestIDForQuestWatchIndex then
		id = C_QuestLog.GetQuestIDForQuestWatchIndex(1)
	end
	if id and id > 0 then return id end
end

local function GetQuestText()
	local id = GetTrackedQuestID()
	if not id then return nil end
	return (GetQuestLink and GetQuestLink(id))
		or (C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(id))
		or ("quest " .. id)
end

-- %q = tracked quest link, %t = target name, %z = zone
local function Expand(msg)
	msg = msg:gsub("%%q", function() return GetQuestText() or "this quest" end)
	msg = msg:gsub("%%t", function() return UnitName("target") or "" end)
	msg = msg:gsub("%%z", function() return GetZoneText() or "" end)
	return msg
end

local function Send(msg, chatType, target)
	if not msg or msg == "" then return end
	msg = Expand(msg)
	if #msg > 255 then msg = msg:sub(1, 255) end
	local ok, err = pcall(SendChat, msg, chatType, nil, target)
	if not ok then Print("Could not send (" .. chatType .. "): " .. tostring(err)) end
end

-- Best chat for "talk to the people around me"
local function GroupChat()
	if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
	if IsInRaid() then return "RAID" end
	if IsInGroup() then return "PARTY" end
	return "SAY"
end

local function FindLFGChannel()
	local id = GetChannelName(DB.lfgChannel)
	if id and id > 0 then return id end
	id = GetChannelName(1) -- usually General
	if id and id > 0 then return id end
end

---------------------------------------------------------------------------
-- Actions (also used by keybindings)
---------------------------------------------------------------------------
function DeckTalk_Phrase(i)
	local p = DB and DB.phrases[i]
	if p and p.text ~= "" then Send(p.text, GroupChat()) end
end

function DeckTalk_Note()
	Send(DB.note, GroupChat())
end

function DeckTalk_LFG()
	if not GetTrackedQuestID() then
		Print("No tracked quest. Track or super-track a quest first.")
		return
	end
	local chan = FindLFGChannel()
	if chan then
		Send(DB.lfgFormat, "CHANNEL", chan)
	else
		Send(DB.lfgFormat, "SAY")
	end
end

function DeckTalk_ReplyNote()
	if not lastWhisperer then Print("Nobody has whispered you yet.") return end
	Send(DB.note, "WHISPER", lastWhisperer)
end

---------------------------------------------------------------------------
-- Main panel
---------------------------------------------------------------------------
local BTN_W, BTN_H, PAD = 150, 34, 6
local panel, buttons = nil, {}

local function UpdateButtons()
	for i = 1, NUM_PHRASES do
		local p = DB.phrases[i]
		buttons[i]:SetText(p and p.label ~= "" and p.label or ("Phrase " .. i))
	end
end

local function SavePosition()
	local point, _, relPoint, x, y = panel:GetPoint()
	DB.pos = { point, relPoint, x, y }
end

local function MakeButton(parent, text, col, row, onClick, tip)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(BTN_W, BTN_H)
	b:SetPoint("TOPLEFT", PAD + col * (BTN_W + PAD), -28 - row * (BTN_H + PAD))
	b:SetText(text)
	b:SetScript("OnClick", onClick)
	if tip then
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(tip(), 1, 1, 1, 1, true)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", GameTooltip_Hide)
	end
	return b
end

local OpenEditor -- forward

local function CreatePanel()
	panel = CreateFrame("Frame", "DeckTalkPanel", UIParent, "BasicFrameTemplateWithInset")
	local rows = NUM_PHRASES / 2 + 2
	panel:SetSize(PAD * 3 + BTN_W * 2, 34 + rows * (BTN_H + PAD))
	panel:SetMovable(true)
	panel:EnableMouse(true)
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", panel.StartMoving)
	panel:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() SavePosition() end)
	panel:SetClampedToScreen(true)
	panel:SetScale(DB.scale or 1)

	if DB.pos then
		panel:SetPoint(DB.pos[1], UIParent, DB.pos[2], DB.pos[3], DB.pos[4])
	else
		panel:SetPoint("RIGHT", UIParent, "RIGHT", -40, 0)
	end

	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	title:SetPoint("TOP", 0, -5)
	title:SetText("DeckTalk")

	panel.CloseButton:HookScript("OnClick", function() DB.shown = false end)

	for i = 1, NUM_PHRASES do
		local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
		buttons[i] = MakeButton(panel, "", col, row, function() DeckTalk_Phrase(i) end,
			function() return Expand(DB.phrases[i].text) .. "\n|cff888888-> " .. GroupChat() .. "|r" end)
	end
	local r = NUM_PHRASES / 2
	MakeButton(panel, "|cff00ff00LFG: quest|r", 0, r, DeckTalk_LFG,
		function() return GetTrackedQuestID() and Expand(DB.lfgFormat) or "No tracked quest" end)
	MakeButton(panel, "|cffffcc00Deck note|r", 1, r, DeckTalk_Note,
		function() return DB.note end)
	MakeButton(panel, "Reply note", 0, r + 1, DeckTalk_ReplyNote,
		function() return lastWhisperer and ("Whisper note to " .. lastWhisperer) or "Nobody has whispered you yet" end)
	MakeButton(panel, "Settings", 1, r + 1, function() OpenEditor() end)

	UpdateButtons()
	panel:SetShown(DB.shown)
end

function DeckTalk_Toggle()
	DB.shown = not panel:IsShown()
	panel:SetShown(DB.shown)
end

---------------------------------------------------------------------------
-- Settings editor
---------------------------------------------------------------------------
local editor

local function MakeEdit(parent, w, x, y)
	local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	e:SetSize(w, 22)
	e:SetPoint("TOPLEFT", x, y)
	e:SetAutoFocus(false)
	e:SetMaxLetters(255)
	e:SetScript("OnEscapePressed", e.ClearFocus)
	e:SetScript("OnEnterPressed", e.ClearFocus)
	return e
end

local function MakeCheck(parent, label, x, y)
	local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	c:SetPoint("TOPLEFT", x, y)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	fs:SetPoint("LEFT", c, "RIGHT", 2, 0)
	fs:SetText(label)
	return c
end

local function Label(parent, text, x, y)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetText(text)
	return fs
end

local function CreateEditor()
	editor = CreateFrame("Frame", "DeckTalkEditor", UIParent, "BasicFrameTemplateWithInset")
	editor:SetSize(520, 470)
	editor:SetPoint("CENTER")
	editor:SetFrameStrata("DIALOG")
	editor:SetMovable(true)
	editor:EnableMouse(true)
	editor:RegisterForDrag("LeftButton")
	editor:SetScript("OnDragStart", editor.StartMoving)
	editor:SetScript("OnDragStop", editor.StopMovingOrSizing)
	tinsert(UISpecialFrames, "DeckTalkEditor") -- Esc closes

	local t = editor:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	t:SetPoint("TOP", 0, -5)
	t:SetText("DeckTalk settings")

	Label(editor, "Button label", 20, -32)
	Label(editor, "Message   (%q = tracked quest, %t = target, %z = zone)", 130, -32)

	editor.labels, editor.texts = {}, {}
	for i = 1, NUM_PHRASES do
		local y = -48 - (i - 1) * 28
		editor.labels[i] = MakeEdit(editor, 100, 20, y)
		editor.texts[i]  = MakeEdit(editor, 360, 135, y)
	end

	local y = -48 - NUM_PHRASES * 28 - 6
	Label(editor, "Steam Deck note", 20, y)
	editor.note = MakeEdit(editor, 475, 25, y - 14)
	y = y - 44
	Label(editor, "LFG message", 20, y)
	editor.lfg = MakeEdit(editor, 475, 25, y - 14)
	y = y - 42
	editor.autoIntro = MakeCheck(editor, "Post note in group chat when I join a group", 16, y)
	editor.autoReply = MakeCheck(editor, "Auto-whisper note back (once per 10 min per player)", 16, y - 26)

	local save = CreateFrame("Button", nil, editor, "UIPanelButtonTemplate")
	save:SetSize(120, 28)
	save:SetPoint("BOTTOMRIGHT", -14, 12)
	save:SetText("Save")
	save:SetScript("OnClick", function()
		for i = 1, NUM_PHRASES do
			DB.phrases[i].label = editor.labels[i]:GetText()
			DB.phrases[i].text  = editor.texts[i]:GetText()
		end
		DB.note      = editor.note:GetText()
		DB.lfgFormat = editor.lfg:GetText()
		DB.autoIntro = editor.autoIntro:GetChecked()
		DB.autoReply = editor.autoReply:GetChecked()
		UpdateButtons()
		editor:Hide()
		Print("Saved.")
	end)

	local reset = CreateFrame("Button", nil, editor, "UIPanelButtonTemplate")
	reset:SetSize(120, 28)
	reset:SetPoint("BOTTOMLEFT", 14, 12)
	reset:SetText("Defaults")
	reset:SetScript("OnClick", function()
		DB.phrases = nil; DB.note = nil; DB.lfgFormat = nil
		CopyDefaults(DEFAULTS, DB)
		UpdateButtons()
		editor:Hide()
		OpenEditor()
	end)
end

function OpenEditor()
	if not editor then CreateEditor() end
	for i = 1, NUM_PHRASES do
		editor.labels[i]:SetText(DB.phrases[i].label or "")
		editor.texts[i]:SetText(DB.phrases[i].text or "")
		editor.labels[i]:SetCursorPosition(0)
		editor.texts[i]:SetCursorPosition(0)
	end
	editor.note:SetText(DB.note); editor.note:SetCursorPosition(0)
	editor.lfg:SetText(DB.lfgFormat); editor.lfg:SetCursorPosition(0)
	editor.autoIntro:SetChecked(DB.autoIntro)
	editor.autoReply:SetChecked(DB.autoReply)
	editor:Show()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")

local function OnWhisper(text, sender)
	if not sender or sender == "" then return end
	lastWhisperer = sender
	if not DB.autoReply then return end
	if text == DB.note then return end -- another DeckTalk user, avoid ping-pong
	local now = GetTime()
	if replied[sender] and now - replied[sender] < REPLY_COOLDOWN then return end
	replied[sender] = now
	Send(DB.note, "WHISPER", sender)
end

ev:SetScript("OnEvent", function(self, event, ...)
	if event == "ADDON_LOADED" then
		if ... ~= ADDON then return end
		DeckTalkDB = CopyDefaults(DEFAULTS, DeckTalkDB or {})
		DB = DeckTalkDB
		CreatePanel()
		self:RegisterEvent("GROUP_JOINED")
		self:RegisterEvent("CHAT_MSG_WHISPER")
		self:UnregisterEvent("ADDON_LOADED")

	elseif event == "GROUP_JOINED" then
		if DB.autoIntro then
			C_Timer.After(3, function()
				if IsInGroup() then Send(DB.note, GroupChat()) end
			end)
		end

	elseif event == "CHAT_MSG_WHISPER" then
		-- pcall: chat payloads can be restricted ("secret") in some combat situations
		pcall(OnWhisper, ...)
	end
end)

---------------------------------------------------------------------------
-- Slash commands & binding labels
---------------------------------------------------------------------------
BINDING_HEADER_DECKTALK = "DeckTalk"
BINDING_NAME_DECKTALK_TOGGLE = "Show/hide panel"
BINDING_NAME_DECKTALK_LFG = "LFG for tracked quest"
BINDING_NAME_DECKTALK_NOTE = "Send Steam Deck note"
BINDING_NAME_DECKTALK_REPLY = "Whisper note to last whisperer"
for i = 1, NUM_PHRASES do
	_G["BINDING_NAME_DECKTALK_PHRASE" .. i] = "Quick phrase " .. i
end

SLASH_DECKTALK1, SLASH_DECKTALK2 = "/decktalk", "/dt"
SlashCmdList.DECKTALK = function(msg)
	local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)$")
	cmd = cmd:lower()
	if cmd == "" then
		DeckTalk_Toggle()
	elseif cmd == "config" or cmd == "edit" then
		OpenEditor()
	elseif cmd == "scale" and tonumber(rest) then
		DB.scale = math.max(0.5, math.min(2, tonumber(rest)))
		panel:SetScale(DB.scale)
	elseif cmd == "reset" then
		DB.pos = nil
		panel:ClearAllPoints()
		panel:SetPoint("RIGHT", UIParent, "RIGHT", -40, 0)
	else
		Print("/dt - show/hide | /dt config - edit phrases | /dt scale 1.3 | /dt reset - move panel back")
	end
end
