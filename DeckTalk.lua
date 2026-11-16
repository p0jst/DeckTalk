-- DeckTalk: one-tap chat for Steam Deck / controller players
-- Works on WoW: Forever and retail (both run the modern client).
local ADDON = ...

---------------------------------------------------------------------------
-- Defaults
---------------------------------------------------------------------------
local NUM_PHRASES = 6
local DEFAULTS = {
	phrases = {
		{ label = "Hi!",         text = "Hi!" },
		{ label = "Thanks!",     text = "Thanks!" },
		{ label = "Yes",         text = "Yes" },
		{ label = "No",          text = "No" },
		{ label = "Inv please?", text = "Could you invite me, please?" },
		{ label = "Group up?",   text = "Want to group up for %q?" },
	},
	note           = "I'm playing on a Steam Deck and typing is slow - sorry if I don't reply much!",
	lfgFormat      = "LFG %q - %w",
	lfgChannel     = "LookingForGroup",
	dest           = "AUTO",  -- AUTO | SAY | GROUP | WHISPER
	role           = "AUTO",  -- AUTO | TANK | HEALER | DAMAGER
	autoIntro      = true,    -- post note in group chat when joining a group
	autoReply      = true,    -- whisper note back to people who whisper you
	replySkipKnown = true,    -- ...but not to friends / guild
	shown          = true,
	collapsed      = false,
	scale          = 1,
}

-- Standard texts offered by the first-run setup (pick up to NUM_PHRASES)
local CATALOG = {
	{ label = "Hi!",          text = "Hi!" },
	{ label = "Thanks!",      text = "Thanks!" },
	{ label = "Yes",          text = "Yes" },
	{ label = "No",           text = "No" },
	{ label = "Inv please?",  text = "Could you invite me, please?" },
	{ label = "Group up?",    text = "Want to group up for %q?" },
	{ label = "One sec",      text = "One sec please." },
	{ label = "Sorry!",       text = "Sorry!" },
	{ label = "Ready",        text = "Ready!" },
	{ label = "On my way",    text = "On my way!" },
	{ label = "BRB",          text = "BRB, back in a minute." },
	{ label = "Thanks, bye!", text = "Thanks for the group, bye!" },
}

local NOTES = {
	{ label = "Steam Deck", text = "I'm playing on a Steam Deck and typing is slow - sorry if I don't reply much!" },
	{ label = "Controller", text = "I'm playing with a controller and typing is slow - sorry if I don't reply much!" },
	{ label = "Handheld",   text = "I'm playing on a handheld and typing is slow - sorry if I don't reply much!" },
}

local ROLE_TEXT  = { TANK = "Tank", HEALER = "Healer", DAMAGER = "DPS" }
local ROLE_CYCLE = { "AUTO", "TANK", "HEALER", "DAMAGER" }
local DESTS      = { "AUTO", "SAY", "GROUP", "WHISPER" }
local DEST_TEXT  = { AUTO = "Auto", SAY = "Say", GROUP = "Group", WHISPER = "Whisper" }
local CHAT_TEXT  = { SAY = "Say", PARTY = "Party", RAID = "Raid", INSTANCE_CHAT = "Instance" }

local REPLY_COOLDOWN   = 600 -- auto-reply once per player per 10 min
local CHAT_COOLDOWN    = 1   -- debounce for say/party/whisper
local CHANNEL_COOLDOWN = 3   -- debounce for LFG/General (spam protection)

local DB
local lastWhisperer
local lastWhisperAt = 0
local WHISPER_WINDOW = 120 -- Auto replies to a whisper this fresh (when not in a group)
local replied = {}
local lastSendAt = { CHAT = 0, CHANNEL = 0 }
local pendingIntro = false

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

-- Older versions stored 8 phrases: keep the first NUM_PHRASES that have text.
local function NormalizePhrases(db)
	if type(db.phrases) ~= "table" then return end
	local keep = {}
	for i = 1, #db.phrases do
		local p = db.phrases[i]
		if type(p) == "table" and type(p.text) == "string" and p.text ~= "" and #keep < NUM_PHRASES then
			tinsert(keep, { label = type(p.label) == "string" and p.label or "", text = p.text })
		end
	end
	for i = #keep + 1, NUM_PHRASES do keep[i] = { label = "", text = "" } end
	db.phrases = keep
end

local SendChat = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage

local function DetectRole()
	local ok, role = pcall(function()
		local getSpec = (C_SpecializationInfo and C_SpecializationInfo.GetSpecialization) or GetSpecialization
		local spec = getSpec and getSpec()
		if spec and spec > 0 then
			if GetSpecializationRole then
				local r = GetSpecializationRole(spec)
				if r then return r end
			end
			local getInfo = (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo) or GetSpecializationInfo
			if getInfo then
				local _, _, _, _, r = getInfo(spec)
				if r then return r end
			end
		end
		return UnitGroupRolesAssigned and UnitGroupRolesAssigned("player")
	end)
	if ok and ROLE_TEXT[role] then return role end
end

local function GetRole()
	if DB.role ~= "AUTO" then return DB.role end
	return DetectRole()
end

-- "Healer, lvl 18 Druid" (role omitted when unknown)
local function WhoText()
	local who = ("lvl %d %s"):format(UnitLevel("player") or 0, (UnitClass("player")) or "")
	local role = GetRole()
	if role then who = ROLE_TEXT[role] .. ", " .. who end
	return who
end

local function GetTrackedQuestID()
	local id = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID()
	if (not id or id == 0) and C_QuestLog and C_QuestLog.GetQuestIDForQuestWatchIndex then
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

local function Tidy(s)
	s = s:gsub("%s+([!?.,])", "%1"):gsub("%s%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	return s
end

-- %q quest  %t target  %w role+level+class
local function Expand(msg, questFallback)
	msg = msg:gsub("%%q", function() return GetQuestText() or questFallback or "this quest" end)
	msg = msg:gsub("%%t", function() return (UnitName("target")) or "" end)
	msg = msg:gsub("%%w", function() return WhoText() end)
	return Tidy(msg)
end

local function GroupChatType()
	if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
	if IsInRaid() then return "RAID" end
	if IsInGroup() then return "PARTY" end
end

-- Where do phrase/note buttons send? Returns chatType, target  or  nil, nil, reason
local function ResolveDest()
	local d = DB.dest
	if d == "SAY" then return "SAY" end
	if d == "GROUP" then
		local g = GroupChatType()
		if g then return g end
		return nil, nil, "You're not in a group."
	end
	if d == "WHISPER" then
		if lastWhisperer then return "WHISPER", lastWhisperer end
		return nil, nil, "Nobody has whispered you yet."
	end
	local g = GroupChatType()
	if g then return g end
	if lastWhisperer and GetTime() - lastWhisperAt < WHISPER_WINDOW then return "WHISPER", lastWhisperer end
	return "SAY"
end

local function GroupHasOtherPlayers()
	local raid = IsInRaid()
	local n = GetNumGroupMembers()
	for i = 1, raid and n or (n - 1) do
		local u = (raid and "raid" or "party") .. i
		if UnitExists(u) and UnitIsPlayer(u) and not UnitIsUnit(u, "player") then return true end
	end
	return false
end

local function FindLFGChannel()
	local id = GetChannelName(DB.lfgChannel)
	if id and id > 0 then return id end
	id = GetChannelName(1) -- usually General
	if id and id > 0 then return id end
end

-- auto = automatic message: skips the debounce and stays quiet on failure
local function Send(msg, chatType, target, auto)
	if not msg or msg == "" or not chatType then return false end
	if not auto then
		local kind = chatType == "CHANNEL" and "CHANNEL" or "CHAT"
		local cd = kind == "CHANNEL" and CHANNEL_COOLDOWN or CHAT_COOLDOWN
		local now = GetTime()
		if now - lastSendAt[kind] < cd then return false end
		lastSendAt[kind] = now
	end
	msg = Expand(msg)
	if #msg > 255 and not msg:find("|H", 1, true) then msg = msg:sub(1, 255) end
	local ok, err = pcall(SendChat, msg, chatType, nil, target)
	if not ok then
		if not auto then Print("Couldn't send: " .. tostring(err)) end
		return false
	end
	return true
end

---------------------------------------------------------------------------
-- Panel (forward declarations used by actions)
---------------------------------------------------------------------------
local panel
local phraseButtons = {}
local lfgButton, noteButton
local OpenEditor, OpenSetup, UpdateTitle
local setup -- first-run setup window, created on demand

local function Flash(btn)
	if not btn or not btn.baseText then return end
	btn:SetText("|cff33ff33Sent!|r")
	if btn.flashTimer then btn.flashTimer:Cancel() end
	btn.flashTimer = C_Timer.NewTimer(1, function()
		btn.flashTimer = nil
		btn:SetText(btn.baseText)
	end)
end

---------------------------------------------------------------------------
-- Actions (also used by keybindings)
---------------------------------------------------------------------------
-- All actions return true when a message was actually sent.
local function SendToDest(text, btn)
	local chatType, target, reason = ResolveDest()
	if not chatType then Print(reason) return false end
	if Send(text, chatType, target) then Flash(btn) return true end
	return false
end

function DeckTalk_Phrase(i)
	if not DB then return false end
	local p = DB.phrases[i]
	if p and p.text ~= "" then return SendToDest(p.text, phraseButtons[i]) end
	return false
end

function DeckTalk_Note()
	if not DB then return false end
	return SendToDest(DB.note, noteButton)
end

function DeckTalk_LFG()
	if not DB then return false end
	-- no tracked quest -> "LFG <zone> - Healer, lvl 18 Druid"
	local msg = Expand(DB.lfgFormat, GetZoneText())
	local chan = FindLFGChannel()
	local ok
	if chan then ok = Send(msg, "CHANNEL", chan) else ok = Send(msg, "SAY") end
	if ok then Flash(lfgButton) end
	return ok
end

local function SetDest(d)
	DB.dest = d
	UpdateTitle()
end

function DeckTalk_CycleDest()
	if not DB then return end
	local idx = 1
	for i, d in ipairs(DESTS) do if d == DB.dest then idx = i end end
	SetDest(DESTS[idx % #DESTS + 1])
end

---------------------------------------------------------------------------
-- Main panel: compact, 2 columns, only as tall as the phrases you use
---------------------------------------------------------------------------
local PAD, GAP, BTN_W, BTN_H, TITLE_H = 5, 4, 112, 24, 24
local FRAME_W = PAD * 2 + BTN_W * 2 + GAP

local function KeyText(action)
	local key = GetBindingKey(action)
	if not key then return "" end
	return GetBindingText(key, true) or key
end

local function ShortName(target)
	local ok, short = pcall(Ambiguate, target, "short")
	return tostring(ok and short or target)
end

-- "Party", "Whisper Bob", or a red warning when the destination can't be used
local function DestLabel()
	local chatType, target = ResolveDest()
	if not chatType then
		return "|cffff5555" .. (DB.dest == "WHISPER" and "no whisper yet" or "not in a group") .. "|r"
	elseif chatType == "WHISPER" then
		return "|cffff80ffWhisper " .. ShortName(target) .. "|r"
	end
	return CHAT_TEXT[chatType] or chatType
end

-- Short form for the title-bar button: "Auto (Say)", "To: Party", "To: Bob"
local function DestShort()
	local chatType, target = ResolveDest()
	if not chatType then
		return "|cffff5555" .. (DB.dest == "WHISPER" and "No whisper" or "No group") .. "|r"
	end
	local name = chatType == "WHISPER" and ("|cffff80ff" .. ShortName(target) .. "|r") or (CHAT_TEXT[chatType] or chatType)
	if DB.dest == "AUTO" then return "Auto (" .. name .. ")" end
	return "To: " .. name
end

local RefreshMenu -- quick chat menu, defined below

function UpdateTitle()
	if panel and panel.destBtn then panel.destBtn:SetText(DestShort()) end
	if RefreshMenu then RefreshMenu() end
end

local function SavePosition()
	DB.pos = { panel:GetLeft(), panel:GetTop() }
end

local function Place(b, slot)
	local col, row = (slot - 1) % 2, math.floor((slot - 1) / 2)
	b:ClearAllPoints()
	b:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD + col * (BTN_W + GAP), -(TITLE_H + PAD + row * (BTN_H + GAP)))
end

-- Positions the buttons, hides unused phrase slots and sizes the panel to fit.
local function Layout()
	if not panel then return end
	local c = DB.collapsed
	local n = 0
	for i = 1, NUM_PHRASES do
		local b, p = phraseButtons[i], DB.phrases[i]
		local has = p ~= nil and p.text ~= nil and p.text ~= ""
		if has then
			n = n + 1
			b.baseText = (p.label and p.label ~= "") and p.label or p.text
			if not b.flashTimer then b:SetText(b.baseText) end
			b.key:SetText(KeyText("DECKTALK_PHRASE" .. i))
			Place(b, n)
		end
		b:SetShown(has and not c)
	end
	local rows = math.ceil(n / 2)
	Place(lfgButton, rows * 2 + 1)
	Place(noteButton, rows * 2 + 2)
	lfgButton:SetShown(not c)
	noteButton:SetShown(not c)
	lfgButton.key:SetText(KeyText("DECKTALK_LFG"))
	noteButton.key:SetText(KeyText("DECKTALK_NOTE"))
	if panel.Inset then panel.Inset:SetShown(not c) end
	local fullH = TITLE_H + PAD + (rows + 1) * (BTN_H + GAP) - GAP + PAD + 1
	panel:SetHeight(c and TITLE_H + 2 or fullH)
	panel.minBtn:SetText(c and "+" or "-")
end

local function ShowPanel()
	DB.shown, DB.collapsed = true, false
	panel:Show()
	Layout()
end

local function ClosePanel()
	DB.shown = false
	panel:Hide()
	if not DB.closeHint then
		DB.closeHint = true
		Print("Panel closed. Get it back with /dt, the \"Show / hide panel\" keybind, or \"Show panel\" in the Quick chat menu.")
	end
end

local function AddTooltip(b, fn)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(fn(), 1, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", GameTooltip_Hide)
end

local function MakeButton(parent, w, h, x, y, text, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(w, h)
	b:SetPoint("TOPLEFT", x, y)
	b:SetText(text or "")
	b:SetScript("OnClick", onClick)
	return b
end

local function FitText(b, w)
	local fs = b:GetFontString()
	if fs then fs:SetWidth(w) fs:SetWordWrap(false) end -- long labels get "..."
end

local function MakeActionButton(onClick)
	local b = MakeButton(panel, BTN_W, BTN_H, 0, 0, "", onClick)
	FitText(b, BTN_W - 26)
	b.key = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	b.key:SetPoint("TOPRIGHT", -4, -3)
	return b
end

local DEST_HELP = {
	AUTO = "Auto: group chat in a group. Alone: answers a whisper from the last 2 minutes, otherwise /say",
	SAY = "Say: players nearby",
	GROUP = "Group: party / raid / instance chat",
	WHISPER = "Whisper: the last person who whispered you",
}

local function CreatePanel()
	panel = CreateFrame("Frame", "DeckTalkPanel", UIParent, "BasicFrameTemplateWithInset")
	panel.phraseButtons = phraseButtons
	panel:SetSize(FRAME_W, TITLE_H + 2)
	panel:SetMovable(true)
	panel:EnableMouse(true)
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", panel.StartMoving)
	panel:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() SavePosition() end)
	panel:SetClampedToScreen(true)
	panel:SetScale(DB.scale or 1)

	if DB.pos and type(DB.pos[1]) == "number" then
		panel:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", DB.pos[1], DB.pos[2])
	else
		panel:SetPoint("LEFT", UIParent, "LEFT", 16, 80)
	end

	-- title bar: [To: Say] ........ [Edit] [-] [X]
	local closeW = 0
	if panel.CloseButton then
		panel.CloseButton:SetScript("OnClick", ClosePanel)
		AddTooltip(panel.CloseButton, function() return "Close (get it back with /dt)" end)
		closeW = 22
	end

	panel.minBtn = MakeButton(panel, 18, 18, 0, 0, "-", function()
		DB.collapsed = not DB.collapsed
		Layout()
	end)
	panel.minBtn:ClearAllPoints()
	panel.minBtn:SetPoint("TOPRIGHT", -4 - closeW, -3)
	AddTooltip(panel.minBtn, function() return DB.collapsed and "Expand" or "Minimize" end)

	local edit = MakeButton(panel, 36, 18, 0, 0, "Edit", function() OpenEditor() end)
	edit:ClearAllPoints()
	edit:SetPoint("RIGHT", panel.minBtn, "LEFT", -2, 0)
	AddTooltip(edit, function() return "Edit phrases and options" end)

	local destW = FRAME_W - 6 - (4 + closeW + 18 + 2 + 36 + 4)
	panel.destBtn = MakeButton(panel, destW, 18, 6, -3, "", DeckTalk_CycleDest)
	FitText(panel.destBtn, destW - 10)
	-- the button covers most of the title bar, so it also works as the drag handle
	panel.destBtn:RegisterForDrag("LeftButton")
	panel.destBtn:SetScript("OnDragStart", function() panel:StartMoving() end)
	panel.destBtn:SetScript("OnDragStop", function() panel:StopMovingOrSizing() SavePosition() end)
	AddTooltip(panel.destBtn, function()
		return "Where messages go\n" .. DEST_HELP[DB.dest] .. "\n|cff999999Click to change, drag to move the panel|r"
	end)

	for i = 1, NUM_PHRASES do
		local b = MakeActionButton(function() DeckTalk_Phrase(i) end)
		AddTooltip(b, function() return Expand(DB.phrases[i].text) end)
		phraseButtons[i] = b
	end

	lfgButton = MakeActionButton(DeckTalk_LFG)
	lfgButton.baseText = "|cff00ff00LFG: quest|r"
	lfgButton:SetText(lfgButton.baseText)
	AddTooltip(lfgButton, function()
		return Expand(DB.lfgFormat, GetZoneText()) .. "\n|cff999999Posted in LookingForGroup (or General)|r"
	end)

	noteButton = MakeActionButton(DeckTalk_Note)
	noteButton.baseText = "|cffffcc00My note|r"
	noteButton:SetText(noteButton.baseText)
	AddTooltip(noteButton, function() return DB.note end)

	UpdateTitle()
	Layout()
	panel:SetShown(DB.shown)
end

-- Keybind / "/dt": show or hide the panel
function DeckTalk_Toggle()
	if not panel then return end
	if panel:IsShown() then ClosePanel() else ShowPanel() end
end

-- Addon compartment (retail minimap dropdown): left = show/hide, right = settings
function DeckTalk_OnCompartmentClick(_, button)
	if button == "RightButton" then OpenEditor() else DeckTalk_Toggle() end
end

function DeckTalk_OnCompartmentEnter(_, frame)
	GameTooltip:SetOwner(frame, "ANCHOR_LEFT")
	GameTooltip:SetText("DeckTalk")
	GameTooltip:AddLine("Left-click: show / hide panel", 1, 1, 1)
	GameTooltip:AddLine("Right-click: edit phrases", 1, 1, 1)
	GameTooltip:Show()
end

function DeckTalk_OnCompartmentLeave()
	GameTooltip:Hide()
end

---------------------------------------------------------------------------
-- Borrowed keys: a window captures D-pad / arrows / Enter / Esc only while
-- it is open. Released on close and just before combat (override bindings
-- can't be changed during combat lockdown).
---------------------------------------------------------------------------
local function CaptureKeys(frame, keys)
	if frame.captured or InCombatLockdown() then return end
	for key, button in pairs(keys) do
		SetOverrideBindingClick(frame, true, key, button)
	end
	frame.captured = true
end

local function ReleaseKeys(frame)
	if not frame or not frame.captured then return end
	if InCombatLockdown() then frame.pendingRelease = true return end
	ClearOverrideBindings(frame)
	frame.captured = false
	frame.pendingRelease = false
end

local function NavKeys(prefix)
	return {
		PADDUP = prefix .. "Up",       UP = prefix .. "Up",
		PADDDOWN = prefix .. "Down",   DOWN = prefix .. "Down",
		PADDLEFT = prefix .. "Left",   LEFT = prefix .. "Left",
		PADDRIGHT = prefix .. "Right", RIGHT = prefix .. "Right",
		PAD1 = prefix .. "OK",         ENTER = prefix .. "OK",
		PAD2 = prefix .. "Back",       ESCAPE = prefix .. "Back",
	}
end

-- invisible buttons the captured keys "click" (key presses count as hardware events)
local function MakeNavButtons(parent, prefix, actions)
	for name, fn in pairs(actions) do
		local b = CreateFrame("Button", prefix .. name, parent)
		b:SetSize(1, 1)
		b:SetScript("OnClick", fn)
	end
end

local function GamePadOn()
	if C_GamePad and C_GamePad.IsEnabled then
		local ok, on = pcall(C_GamePad.IsEnabled)
		if ok and on then return true end
	end
	return GetCVarBool and GetCVarBool("GamePadEnable") or false
end

---------------------------------------------------------------------------
-- Quick chat menu: one bind opens it, D-pad / arrows choose, A / Enter send.
-- Needs no cursor, so it works in WoW: Forever's native Gamepad mode, with
-- ConsolePort, and with Steam Input keyboard mappings alike.
---------------------------------------------------------------------------
local menu
local menuItems, menuSel, menuIdle = {}, 1, nil
local MENU_W, ROW_H, MENU_TOP, MENU_FOOT = 320, 30, 34, 58
local MENU_ROWS = NUM_PHRASES + 3
local MENU_IDLE = 12 -- seconds before the menu closes by itself
local MENU_KEYS = NavKeys("DeckTalkMenu")

local function BuildMenuItems()
	wipe(menuItems)
	for i = 1, NUM_PHRASES do
		local p = DB.phrases[i]
		if p and p.text ~= "" then
			tinsert(menuItems, {
				label = (p.label ~= "" and p.label) or p.text,
				run = function() return DeckTalk_Phrase(i) end,
				preview = function() return "|cff999999Sends:|r " .. Expand(p.text) end,
			})
		end
	end
	tinsert(menuItems, { label = "|cff00ff00LFG: quest|r", run = DeckTalk_LFG,
		preview = function() return "|cff999999Sends:|r " .. Expand(DB.lfgFormat, GetZoneText()) .. "  |cff999999(LFG channel)|r" end })
	tinsert(menuItems, { label = "|cffffcc00My note|r", run = DeckTalk_Note,
		preview = function() return "|cff999999Sends:|r " .. DB.note end })
	if panel and not panel:IsShown() then
		tinsert(menuItems, { label = "|cff999999Show panel|r", run = function() ShowPanel() return true end,
			preview = function() return "Puts the button panel back on screen" end })
	end
	if menuSel > #menuItems then menuSel = 1 end
end

local function MenuHint()
	local next, send = KeyText("DECKTALK_MENU"), KeyText("DECKTALK_MENU_SEND")
	local extra = (next ~= "" and ("   " .. next .. ": next") or "") .. (send ~= "" and ("   " .. send .. ": send") or "")
	if not menu.captured then
		return "|cffff9933In combat:|r tap a row" .. extra
	end
	if GamePadOn() then
		return "D-pad: choose   A: send   B: close   Left/Right: where" .. extra
	end
	return "Up/Down: choose   Enter: send   Esc: close   Left/Right: where" .. extra
end

RefreshMenu = function()
	if not menu or not menu:IsShown() then return end
	for i = 1, MENU_ROWS do
		local row, item = menu.rows[i], menuItems[i]
		row:SetShown(item ~= nil)
		if item then
			row.text:SetText(item.label)
			row.text:SetTextColor(1, 1, 1)
		end
	end
	local selRow = menu.rows[menuSel]
	menu.sel:ClearAllPoints()
	menu.sel:SetPoint("TOPLEFT", selRow, "TOPLEFT", 0, 0)
	menu.sel:SetPoint("BOTTOMRIGHT", selRow, "BOTTOMRIGHT", 0, 0)
	menu.title:SetText("Quick chat  |cff999999to|r " .. DestLabel())
	local item = menuItems[menuSel]
	menu.preview:SetText(item and item.preview() or "")
	menu.hint:SetText(MenuHint())
	menu:SetHeight(MENU_TOP + #menuItems * ROW_H + MENU_FOOT)
end

local function MenuIdle()
	if menuIdle then menuIdle:Cancel() end
	menuIdle = C_Timer.NewTimer(MENU_IDLE, function() menuIdle = nil menu:Hide() end)
end

local function MenuMove(step)
	local n = #menuItems
	if n == 0 then return end
	menuSel = (menuSel - 1 + step) % n + 1
	RefreshMenu()
	MenuIdle()
end

local function MenuSend()
	local item = menuItems[menuSel]
	if not item then return end
	if item.run() then menu:Hide() else MenuIdle() end -- stay open if it couldn't send
end

local function MenuDest(step)
	local idx = 1
	for i, d in ipairs(DESTS) do if d == DB.dest then idx = i end end
	SetDest(DESTS[(idx - 1 + step) % #DESTS + 1]) -- also refreshes the menu
	MenuIdle()
end

local function CreateMenu()
	menu = CreateFrame("Frame", "DeckTalkMenu", UIParent, "BasicFrameTemplateWithInset")
	menu:SetSize(MENU_W, MENU_TOP + MENU_ROWS * ROW_H + MENU_FOOT)
	menu:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
	menu:SetFrameStrata("DIALOG")
	menu:SetClampedToScreen(true)
	menu:EnableMouse(true)
	menu:Hide()
	tinsert(UISpecialFrames, "DeckTalkMenu") -- Esc also closes when keys aren't captured
	if menu.CloseButton then menu.CloseButton:SetScript("OnClick", function() menu:Hide() end) end

	menu.title = menu:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	menu.title:SetPoint("TOPLEFT", 10, -6)
	menu.title:SetWidth(MENU_W - 40)
	menu.title:SetJustifyH("LEFT")
	menu.title:SetWordWrap(false)

	menu.sel = menu:CreateTexture(nil, "ARTWORK")
	menu.sel:SetColorTexture(0.27, 0.88, 0.82, 0.28)

	menu.rows = {}
	for i = 1, MENU_ROWS do
		local row = CreateFrame("Button", nil, menu)
		row:SetSize(MENU_W - 24, ROW_H - 2)
		row:SetPoint("TOPLEFT", 12, -MENU_TOP - (i - 1) * ROW_H)
		row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
		row.text:SetPoint("LEFT", 10, 0)
		row.text:SetWidth(MENU_W - 48)
		row.text:SetJustifyH("LEFT")
		row.text:SetWordWrap(false)
		local hl = row:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.08)
		row:SetScript("OnClick", function() menuSel = i MenuSend() end)
		menu.rows[i] = row
	end

	menu.preview = menu:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	menu.preview:SetPoint("BOTTOMLEFT", 14, 32)
	menu.preview:SetWidth(MENU_W - 28)
	menu.preview:SetJustifyH("LEFT")
	menu.preview:SetWordWrap(false)

	menu.hint = menu:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	menu.hint:SetPoint("BOTTOMLEFT", 14, 12)
	menu.hint:SetWidth(MENU_W - 28)
	menu.hint:SetJustifyH("LEFT")
	menu.hint:SetWordWrap(false)

	MakeNavButtons(menu, "DeckTalkMenu", {
		Up = function() MenuMove(-1) end,
		Down = function() MenuMove(1) end,
		OK = MenuSend,
		Back = function() menu:Hide() end,
		Left = function() MenuDest(-1) end,
		Right = function() MenuDest(1) end,
	})

	menu:SetScript("OnHide", function()
		if menuIdle then menuIdle:Cancel() menuIdle = nil end
		ReleaseKeys(menu)
	end)

	if ConsolePort and ConsolePort.AddInterfaceCursorFrame then
		pcall(ConsolePort.AddInterfaceCursorFrame, ConsolePort, menu)
	end
end

-- Bind 1: open, or move to the next entry when already open
function DeckTalk_QuickMenu()
	if not DB then return end
	if setup and setup:IsShown() then return end -- setup owns the D-pad right now
	if not menu then CreateMenu() end
	if menu:IsShown() then MenuMove(1) return end
	BuildMenuItems()
	menu:Show()
	CaptureKeys(menu, MENU_KEYS)
	RefreshMenu()
	MenuIdle()
end

-- Bind 2: send the selected entry (for back-button-only setups)
function DeckTalk_MenuSend()
	if menu and menu:IsShown() then MenuSend() end
end

---------------------------------------------------------------------------
-- Settings editor
---------------------------------------------------------------------------
local editor
local EDITOR_W, EDITOR_H = 520, 478

local function MakeEdit(parent, w, x, y, maxLetters)
	local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	e:SetSize(w, 22)
	e:SetPoint("TOPLEFT", x, y)
	e:SetAutoFocus(false)
	e:SetMaxLetters(maxLetters or 255)
	e:SetScript("OnEscapePressed", e.ClearFocus)
	e:SetScript("OnEnterPressed", e.ClearFocus)
	return e
end

local function MakeCheck(parent, label, x, y)
	local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	c:SetSize(26, 26)
	c:SetPoint("TOPLEFT", x, y)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	fs:SetPoint("LEFT", c, "RIGHT", 4, 0)
	fs:SetText(label)
	return c
end

local function Label(parent, text, x, y, font)
	local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetJustifyH("LEFT")
	fs:SetText(text)
	return fs
end

local function RoleButtonText(role)
	if role == "AUTO" then
		local d = DetectRole()
		return "Role: Auto (" .. (d and ROLE_TEXT[d] or "not detected") .. ")"
	end
	return "Role: " .. ROLE_TEXT[role]
end

local function UpdatePreview()
	-- preview with the role chosen in the editor, not the saved one
	local saved = DB.role
	DB.role = editor.role
	editor.preview:SetText("Preview: " .. Expand(editor.lfg:GetText(), GetZoneText()))
	DB.role = saved
end

local function FillEditor(src)
	for i = 1, NUM_PHRASES do
		editor.labels[i]:SetText(src.phrases[i].label or "")
		editor.texts[i]:SetText(src.phrases[i].text or "")
		editor.labels[i]:SetCursorPosition(0)
		editor.texts[i]:SetCursorPosition(0)
	end
	editor.note:SetText(src.note); editor.note:SetCursorPosition(0)
	editor.lfg:SetText(src.lfgFormat); editor.lfg:SetCursorPosition(0)
	editor.role = src.role
	editor.roleBtn:SetText(RoleButtonText(editor.role))
	editor.autoIntro:SetChecked(src.autoIntro)
	editor.autoReply:SetChecked(src.autoReply)
	UpdatePreview()
end

local function CreateEditor()
	editor = CreateFrame("Frame", "DeckTalkEditor", UIParent, "BasicFrameTemplateWithInset")
	editor:SetSize(EDITOR_W, EDITOR_H)
	editor:SetPoint("CENTER")
	editor:SetFrameStrata("DIALOG")
	editor:SetMovable(true)
	editor:EnableMouse(true)
	editor:RegisterForDrag("LeftButton")
	editor:SetScript("OnDragStart", editor.StartMoving)
	editor:SetScript("OnDragStop", editor.StopMovingOrSizing)
	editor:SetClampedToScreen(true)
	tinsert(UISpecialFrames, "DeckTalkEditor") -- Esc closes

	local t = editor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	t:SetPoint("TOPLEFT", 10, -6)
	t:SetText("DeckTalk settings")

	Label(editor, "Button label", 22, -32)
	Label(editor, "Message  (leave empty to remove the button)", 135, -32)

	local order = {}
	editor.labels, editor.texts = {}, {}
	local y = -46
	for i = 1, NUM_PHRASES do
		editor.labels[i] = MakeEdit(editor, 100, 24, y, 16)
		editor.texts[i]  = MakeEdit(editor, 360, 137, y)
		tinsert(order, editor.labels[i])
		tinsert(order, editor.texts[i])
		y = y - 28
	end

	Label(editor, "My note (also the auto-reply)", 22, y - 6)
	editor.note = MakeEdit(editor, 473, 24, y - 20)
	Label(editor, "LFG message", 22, y - 48)
	editor.lfg = MakeEdit(editor, 473, 24, y - 62)
	tinsert(order, editor.note)
	tinsert(order, editor.lfg)

	editor.preview = Label(editor, "", 22, y - 88, "GameFontHighlightSmall")
	editor.preview:SetWidth(EDITOR_W - 44)
	editor.preview:SetWordWrap(false)
	editor.lfg:SetScript("OnTextChanged", UpdatePreview)

	local help = Label(editor,
		"You can use:  %q tracked quest    %t target's name    %w role, level, class", 22, y - 106, "GameFontDisableSmall")
	help:SetWidth(EDITOR_W - 44)

	-- Tab / Shift-Tab between fields
	for i, e in ipairs(order) do
		e:SetScript("OnTabPressed", function(self)
			self:ClearFocus()
			local step = IsShiftKeyDown() and -1 or 1
			order[(i - 1 + step) % #order + 1]:SetFocus()
		end)
	end

	editor.roleBtn = MakeButton(editor, 200, 22, 22, y - 126, "", function(self)
		local idx = 1
		for i, r in ipairs(ROLE_CYCLE) do if r == editor.role then idx = i end end
		editor.role = ROLE_CYCLE[idx % #ROLE_CYCLE + 1]
		self:SetText(RoleButtonText(editor.role))
		UpdatePreview()
	end)
	Label(editor, "Click to change. Auto uses your current spec.", 230, y - 132, "GameFontDisableSmall")

	editor.autoIntro = MakeCheck(editor, "Post my note in group chat when I join a group", 18, y - 156)
	editor.autoReply = MakeCheck(editor, "Whisper my note back to strangers who whisper me", 18, y - 182)

	local save = MakeButton(editor, 100, 26, 0, 0, "Save", function()
		for i = 1, NUM_PHRASES do
			DB.phrases[i].label = editor.labels[i]:GetText()
			DB.phrases[i].text  = editor.texts[i]:GetText()
		end
		DB.note           = editor.note:GetText()
		DB.lfgFormat      = editor.lfg:GetText()
		DB.role           = editor.role
		DB.autoIntro      = editor.autoIntro:GetChecked()
		DB.autoReply      = editor.autoReply:GetChecked()
		Layout()
		editor:Hide()
		Print("Saved.")
	end)
	save:ClearAllPoints()
	save:SetPoint("BOTTOMRIGHT", -14, 12)

	local cancel = MakeButton(editor, 100, 26, 0, 0, "Cancel", function() editor:Hide() end)
	cancel:ClearAllPoints()
	cancel:SetPoint("RIGHT", save, "LEFT", -8, 0)

	local defaults = MakeButton(editor, 100, 26, 0, 0, "Defaults", function()
		FillEditor(DEFAULTS)
		Print("Defaults loaded into the editor - press Save to keep them.")
	end)
	defaults:ClearAllPoints()
	defaults:SetPoint("BOTTOMLEFT", 14, 12)

	local again = MakeButton(editor, 130, 26, 0, 0, "Run setup again", function()
		editor:Hide()
		OpenSetup()
	end)
	again:ClearAllPoints()
	again:SetPoint("LEFT", defaults, "RIGHT", 8, 0)

	if ConsolePort and ConsolePort.AddInterfaceCursorFrame then
		pcall(ConsolePort.AddInterfaceCursorFrame, ConsolePort, editor)
	end
end

function OpenEditor()
	if not editor then CreateEditor() end
	FillEditor(DB)
	editor:Show()
end

---------------------------------------------------------------------------
-- First-run setup: pick your standard texts (max NUM_PHRASES), your note and
-- whether the panel is on screen. Works with cursor, D-pad or keyboard.
-- "A, A" accepts the defaults.
---------------------------------------------------------------------------
local SETUP_W, SETUP_H = 440, 344
local SETUP_KEYS = NavKeys("DeckTalkSetup")
local setupPending = false
local RefreshSetup

local function MakeOption(parent, w, x, y, text, onClick)
	local row = CreateFrame("Button", nil, parent)
	row:SetSize(w, 24)
	row:SetPoint("TOPLEFT", x, y)
	local box = row:CreateTexture(nil, "ARTWORK")
	box:SetSize(22, 22)
	box:SetPoint("LEFT", 0, 0)
	box:SetTexture("Interface\\Buttons\\UI-CheckBox-Up")
	row.check = row:CreateTexture(nil, "OVERLAY")
	row.check:SetSize(22, 22)
	row.check:SetPoint("LEFT", 0, 0)
	row.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
	row.check:Hide()
	row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.label:SetPoint("LEFT", 26, 0)
	row.label:SetWidth(w - 28)
	row.label:SetJustifyH("LEFT")
	row.label:SetWordWrap(false)
	row.label:SetText(text)
	local hl = row:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.08)
	row:SetScript("OnClick", onClick)
	return row
end

local function SetOption(row, on, dim)
	row.on = on and true or false
	row.check:SetShown(row.on)
	if dim then row.label:SetTextColor(0.5, 0.5, 0.5) else row.label:SetTextColor(1, 1, 1) end
end

local function SetupCount()
	local n = 0
	for i = 1, #CATALOG do if setup.sel[i] then n = n + 1 end end
	return n
end

RefreshSetup = function()
	if not setup or not setup:IsShown() then return end
	local p = setup.page
	setup.title:SetText("DeckTalk setup  |cff999999(" .. p .. " of 3)|r")
	for i, page in ipairs(setup.pages) do page:SetShown(i == p) end

	local bound = KeyText("DECKTALK_MENU")
	setup.bindStatus:SetText("Quick chat button:  " .. (bound ~= "" and ("|cff33ff33" .. bound .. "|r") or "|cffff9933none yet|r"))
	setup.chooseBtn:SetText(bound ~= "" and "Change button" or "Choose button")

	local count = SetupCount()
	for i, row in ipairs(setup.options) do
		SetOption(row, setup.sel[i], not setup.sel[i] and count >= NUM_PHRASES)
	end
	setup.counter:SetText(count .. " of " .. NUM_PHRASES .. " chosen" ..
		(count >= NUM_PHRASES and "  |cffff9933(untick one to swap)|r" or ""))

	local note = setup.noteEdit:GetText()
	for k, row in ipairs(setup.noteOpts) do SetOption(row, NOTES[k].text == note) end
	if setup.noteEdit:HasFocus() then
		setup.noteHelp:SetText("|cffffcc00Typing...|r Press Enter when you're done.")
	elseif note:match("^%s*$") then
		setup.noteHelp:SetText("|cffff5555Empty|r - pick a starting point above.")
	else
		setup.noteHelp:SetText(#note .. "/255  -  Select the field and press A to type (Steam + X opens the keyboard).")
	end
	SetOption(setup.checks.intro, setup.autoIntro)
	SetOption(setup.checks.reply, setup.autoReply)
	SetOption(setup.checks.panel, setup.showPanel)

	local items = setup.pages[p].items
	local f = items[setup.focus[p]]
	setup.focusTex:ClearAllPoints()
	setup.focusTex:SetPoint("TOPLEFT", f, "TOPLEFT", -3, 3)
	setup.focusTex:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 3, -3)

	local idx = p == 1 and f.catalogIndex
	setup.sends:SetText(idx and ("|cff999999Sends:|r " .. CATALOG[idx].text:gsub("%%q", "[your tracked quest]")) or "")

	if setup.capturing then
		setup.hint:SetText("Waiting for a button...   Esc / B: cancel")
	elseif not setup.captured then
		setup.hint:SetText("Use the cursor to choose")
	elseif GamePadOn() then
		setup.hint:SetText("D-pad: move   A: choose   B: back")
	else
		setup.hint:SetText("Arrows: move   Enter: choose   Esc: back")
	end
end

local function SetupMove(dx, dy)
	if setup.noteEdit:HasFocus() then setup.noteEdit:ClearFocus() end -- D-pad leaves the text field
	local page = setup.pages[setup.page]
	local idx = setup.focus[setup.page] + dx + dy * page.cols
	if dy > 0 and idx > #page.items then idx = #page.items end -- last row may be shorter
	if idx >= 1 and idx <= #page.items then
		setup.focus[setup.page] = idx
		RefreshSetup()
	end
end

local function SetupPage(p)
	setup.page = p
	RefreshSetup()
end

local function SetupFinish()
	-- phrases: only touched if the selection changed
	local changed = false
	for i = 1, #CATALOG do
		if (setup.sel[i] or false) ~= (setup.initial[i] or false) then changed = true end
	end
	if changed then
		local list, inCatalog = {}, {}
		for i, c in ipairs(CATALOG) do
			inCatalog[c.text] = true
			if setup.sel[i] and #list < NUM_PHRASES then tinsert(list, { label = c.label, text = c.text }) end
		end
		for i = 1, NUM_PHRASES do -- keep the user's own custom phrases while there is room
			local p = DB.phrases[i]
			if p and p.text ~= "" and not inCatalog[p.text] and #list < NUM_PHRASES then
				tinsert(list, { label = p.label, text = p.text })
			end
		end
		for i = #list + 1, NUM_PHRASES do list[i] = { label = "", text = "" } end
		DB.phrases = list
	end
	local note = setup.noteEdit:GetText():gsub("^%s+", ""):gsub("%s+$", "")
	if note ~= "" then DB.note = note end
	DB.autoIntro = setup.autoIntro
	DB.autoReply = setup.autoReply
	DB.setupDone = true
	setup:Hide()
	if setup.showPanel then
		DB.shown = true
		panel:Show()
	else
		DB.shown = false
		panel:Hide()
	end
	Layout()
	local key = KeyText("DECKTALK_MENU")
	if key ~= "" then
		Print("All set! Press " .. key .. " to open Quick chat. Change anything later with /dt setup.")
	else
		Print("All set! Quick chat has no button yet - give it one with /dt setup.")
	end
end

-- Step 3: "press the button you want" - binds the Quick chat menu without a trip
-- to the keybinding screen.
local BIND_ACTION = "DECKTALK_MENU"
local MODIFIER_KEYS = { LSHIFT = 1, RSHIFT = 1, LCTRL = 1, RCTRL = 1, LALT = 1, RALT = 1, LMETA = 1, RMETA = 1, UNKNOWN = 1 }

local function StopCapture(msg)
	if not setup or not setup.capturing then return end
	setup.capturing, setup.bindConfirm = false, nil
	if setup.captureTimer then setup.captureTimer:Cancel() setup.captureTimer = nil end
	setup.capture:Hide()
	if msg then setup.bindMsg:SetText(msg) end
	if setup:IsShown() then CaptureKeys(setup, SETUP_KEYS) end
	RefreshSetup()
end

local function ApplyBind(combo)
	if InCombatLockdown() then
		StopCapture("|cffff5555Buttons can't be changed in combat.|r Try again afterwards.")
		return
	end
	pcall(function()
		for _, old in ipairs({ GetBindingKey(BIND_ACTION) }) do SetBinding(old) end
		SetBinding(combo, BIND_ACTION)
		if SaveBindings and GetCurrentBindingSet then SaveBindings(GetCurrentBindingSet()) end
	end)
	if GetBindingKey(BIND_ACTION) then
		setup.focus[3] = #setup.pages[3].items -- move on to Finish
		StopCapture("|cff33ff33Done!|r Press " .. KeyText(BIND_ACTION) .. " any time to open Quick chat.")
		Layout()
	else
		StopCapture("|cffff5555That one didn't work.|r Try another button.")
	end
end

local function OnCaptured(key)
	if not setup.capturing or MODIFIER_KEYS[key] then return end
	local combo = (IsAltKeyDown() and "ALT-" or "") .. (IsControlKeyDown() and "CTRL-" or "")
		.. (IsShiftKeyDown() and "SHIFT-" or "") .. key
	if combo == "ESCAPE" or combo == "PAD2" then StopCapture("Cancelled.") return end
	if SETUP_KEYS[combo] then
		setup.bindMsg:SetText("|cffff9933That button moves around in DeckTalk's menus.|r Press another one.")
		return
	end
	local action = GetBindingAction and GetBindingAction(combo) or ""
	if action ~= "" and action ~= BIND_ACTION and setup.bindConfirm ~= combo then
		setup.bindConfirm = combo
		local name = (GetBindingName and GetBindingName(action)) or action
		setup.bindMsg:SetText("|cffff9933" .. (GetBindingText(combo, true) or combo) .. " is used for \"" .. name
			.. "\".|r Press it again to use it anyway, or press another button.")
		return
	end
	ApplyBind(combo)
end

local function StartCapture()
	if InCombatLockdown() then
		setup.bindMsg:SetText("|cffff5555Buttons can't be changed in combat.|r Try again afterwards.")
		return
	end
	ReleaseKeys(setup) -- so every button reaches the capture frame
	setup.capturing, setup.bindConfirm = true, nil
	setup.bindMsg:SetText("|cffffcc00Press the button or combo you want now...|r")
	setup.capture:Show()
	if setup.captureTimer then setup.captureTimer:Cancel() end
	setup.captureTimer = C_Timer.NewTimer(10, function()
		setup.captureTimer = nil
		StopCapture("No button pressed. Choose again when you're ready.")
	end)
	RefreshSetup()
end

local function CreateSetup()
	setup = CreateFrame("Frame", "DeckTalkSetup", UIParent, "BasicFrameTemplateWithInset")
	setup:SetSize(SETUP_W, SETUP_H)
	setup:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
	setup:SetFrameStrata("DIALOG")
	setup:SetClampedToScreen(true)
	setup:EnableMouse(true)
	setup:Hide()
	tinsert(UISpecialFrames, "DeckTalkSetup") -- Esc closes when keys aren't captured
	if setup.CloseButton then setup.CloseButton:SetScript("OnClick", function() setup:Hide() end) end

	setup.title = setup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	setup.title:SetPoint("TOPLEFT", 10, -6)
	setup.sel, setup.initial, setup.focus, setup.page = {}, {}, { 1, 1 }, 1
	setup.pages, setup.options, setup.noteOpts, setup.checks = {}, {}, {}, {}

	local function Page(cols)
		local page = CreateFrame("Frame", nil, setup)
		page:SetAllPoints()
		page.items, page.cols = {}, cols
		tinsert(setup.pages, page)
		return page
	end
	local function BottomButton(page, text, fromRight, onClick)
		local b = MakeButton(page, 110, 26, 0, 0, text, onClick)
		b:ClearAllPoints()
		b:SetPoint("BOTTOMRIGHT", setup, "BOTTOMRIGHT", -14 - fromRight * 118, 30)
		return b
	end

	-- page 1: standard texts ------------------------------------------------
	local p1 = Page(2)
	Label(p1, "Welcome to DeckTalk!", 22, -34, "GameFontNormalLarge")
	Label(p1, "Pick the messages you want one press away. You can reword them later.", 22, -56, "GameFontHighlightSmall")
	for i, c in ipairs(CATALOG) do
		local col, r = (i - 1) % 2, math.floor((i - 1) / 2)
		local row = MakeOption(p1, 190, 24 + col * 204, -78 - r * 26, c.label, function()
			if setup.sel[i] then
				setup.sel[i] = false
			elseif SetupCount() < NUM_PHRASES then
				setup.sel[i] = true
			end
			RefreshSetup()
		end)
		row.catalogIndex = i
		row:SetScript("OnEnter", function() setup.focus[1] = i RefreshSetup() end)
		setup.options[i] = row
		tinsert(p1.items, row)
	end
	setup.counter = Label(p1, "", 24, -240, "GameFontNormalSmall")
	setup.sends = Label(p1, "", 24, -256, "GameFontHighlightSmall")
	setup.sends:SetWidth(SETUP_W - 48)
	setup.sends:SetWordWrap(false)
	setup.nextBtn = BottomButton(p1, "Next", 0, function() SetupPage(2) end)
	tinsert(p1.items, setup.nextBtn)

	-- page 2: note + panel ---------------------------------------------------
	local p2 = Page(1)
	Label(p2, "Your auto-reply note", 22, -34, "GameFontNormalLarge")
	Label(p2, "Pick a starting point, then change the text to your own words:", 22, -56, "GameFontHighlightSmall")
	for k, n in ipairs(NOTES) do
		local row = MakeOption(p2, 124, 24 + (k - 1) * 130, -76, n.label, function()
			setup.noteEdit:SetText(NOTES[k].text)
			setup.noteEdit:SetCursorPosition(0)
			RefreshSetup()
		end)
		setup.noteOpts[k] = row
		tinsert(p2.items, row)
	end
	local edit = MakeEdit(p2, SETUP_W - 56, 30, -104, 255)
	edit:SetScript("OnTextChanged", function() RefreshSetup() end)
	edit:SetScript("OnEditFocusGained", function() RefreshSetup() end)
	edit:SetScript("OnEditFocusLost", function() RefreshSetup() end)
	edit.Click = function(self) self:SetFocus() end -- A / Enter on the field starts typing
	setup.noteEdit = edit
	tinsert(p2.items, edit)
	setup.noteHelp = Label(p2, "", 26, -130, "GameFontDisableSmall")
	setup.noteHelp:SetWidth(SETUP_W - 52)
	local function Check(key, y, text, field)
		local row = MakeOption(p2, 392, 24, y, text, function()
			setup[field] = not setup[field]
			RefreshSetup()
		end)
		setup.checks[key] = row
		tinsert(p2.items, row)
	end
	Check("intro", -164, "Post the note in group chat when I join a group", "autoIntro")
	Check("reply", -190, "Whisper the note back to people who whisper me", "autoReply")
	Check("panel", -216, "Keep the small button panel on screen", "showPanel")
	tinsert(p2.items, BottomButton(p2, "Back", 1, function() SetupPage(1) end))
	tinsert(p2.items, BottomButton(p2, "Next", 0, function() SetupPage(3) end))

	-- page 3: one button for Quick chat ---------------------------------------
	local p3 = Page(1)
	Label(p3, "One button for everything", 22, -34, "GameFontNormalLarge")
	local intro = Label(p3, "Quick chat is a menu you steer with the D-pad: choose a message, press A, sent. "
		.. "Give it a button you can reach while playing.", 22, -56, "GameFontHighlightSmall")
	intro:SetWidth(SETUP_W - 44)
	setup.bindStatus = Label(p3, "", 24, -102, "GameFontNormalLarge")
	setup.chooseBtn = MakeButton(p3, 170, 28, 24, -130, "Choose button", StartCapture)
	tinsert(p3.items, setup.chooseBtn)
	setup.bindMsg = Label(p3, "", 24, -170, "GameFontHighlightSmall")
	setup.bindMsg:SetWidth(SETUP_W - 48)
	local tip = Label(p3, "Steam Deck tip: in Steam's controller settings, give a back grip button (L4 / R4) "
		.. "a key such as F7 first. Then choose it here.", 24, -222, "GameFontDisableSmall")
	tip:SetWidth(SETUP_W - 48)
	tinsert(p3.items, BottomButton(p3, "Back", 1, function() SetupPage(2) end))
	setup.finishBtn = BottomButton(p3, "Finish", 0, SetupFinish)
	tinsert(p3.items, setup.finishBtn)

	-- swallows the next key / gamepad button while "Choose button" is waiting
	local cap = CreateFrame("Frame", nil, setup)
	cap:SetAllPoints()
	cap:SetFrameLevel((setup:GetFrameLevel() or 0) + 30)
	cap:EnableMouse(true)
	cap:EnableKeyboard(true)
	if cap.SetPropagateKeyboardInput then cap:SetPropagateKeyboardInput(false) end
	if cap.EnableGamePadButton then cap:EnableGamePadButton(true) end
	cap:SetScript("OnKeyDown", function(_, key) OnCaptured(key) end)
	cap:SetScript("OnGamePadButtonDown", function(_, key) OnCaptured(key) end)
	cap:Hide()
	setup.capture = cap

	-- focus marker sits above the buttons it highlights
	local overlay = CreateFrame("Frame", nil, setup)
	overlay:SetAllPoints()
	overlay:SetFrameLevel((setup:GetFrameLevel() or 0) + 20)
	setup.focusTex = overlay:CreateTexture(nil, "OVERLAY")
	setup.focusTex:SetColorTexture(0.27, 0.88, 0.82, 0.30)

	setup.hint = setup:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	setup.hint:SetPoint("BOTTOMLEFT", 14, 12)

	MakeNavButtons(setup, "DeckTalkSetup", {
		Up = function() SetupMove(0, -1) end,
		Down = function() SetupMove(0, 1) end,
		Left = function() SetupMove(-1, 0) end,
		Right = function() SetupMove(1, 0) end,
		OK = function()
			local page = setup.pages[setup.page]
			page.items[setup.focus[setup.page]]:Click()
		end,
		Back = function()
			if setup.page > 1 then SetupPage(setup.page - 1) else setup:Hide() end
		end,
	})

	setup:SetScript("OnHide", function()
		setup.noteEdit:ClearFocus()
		setup.capturing, setup.bindConfirm = false, nil
		if setup.captureTimer then setup.captureTimer:Cancel() setup.captureTimer = nil end
		setup.capture:Hide()
		ReleaseKeys(setup)
		if not DB.setupDone then
			DB.setupDone = true
			Print("Setup skipped - the standard texts are active. Run it any time with /dt setup.")
		end
	end)

	if ConsolePort and ConsolePort.AddInterfaceCursorFrame then
		pcall(ConsolePort.AddInterfaceCursorFrame, ConsolePort, setup)
	end
end

function OpenSetup()
	if not setup then CreateSetup() end
	if menu and menu:IsShown() then menu:Hide() end
	-- tick the standard texts that are in use right now
	local used = {}
	for i = 1, NUM_PHRASES do
		local p = DB.phrases[i]
		if p and p.text ~= "" then used[p.text] = true end
	end
	for i, c in ipairs(CATALOG) do
		setup.sel[i] = used[c.text] or false
		setup.initial[i] = setup.sel[i]
	end
	setup.noteEdit:SetText(DB.note or "")
	setup.noteEdit:SetCursorPosition(0)
	setup.autoIntro, setup.autoReply = DB.autoIntro and true or false, DB.autoReply and true or false
	setup.showPanel = DB.shown and true or false
	setup.page = 1
	setup.focus[1] = #setup.pages[1].items -- Next
	setup.focus[2] = #setup.pages[2].items -- Next
	setup.focus[3] = GetBindingKey("DECKTALK_MENU") and #setup.pages[3].items or 1 -- Finish, or Choose button
	setup.bindMsg:SetText("")
	setup:Show()
	CaptureKeys(setup, SETUP_KEYS)
	RefreshSetup()
end

local function AutoSetup()
	if DB.setupDone then return end
	if InCombatLockdown() then setupPending = true return end -- wait until combat ends
	setupPending = false
	OpenSetup()
end

---------------------------------------------------------------------------
-- Automatic messages
---------------------------------------------------------------------------
local function TryIntro()
	if not pendingIntro then return end
	if InCombatLockdown() then return end -- retried on PLAYER_REGEN_ENABLED
	pendingIntro = false
	if not DB.autoIntro then return end
	local ok, hasPlayers = pcall(GroupHasOtherPlayers) -- skip NPC-only groups
	if not ok or not hasPlayers then return end
	local chatType = GroupChatType()
	if chatType then Send(DB.note, chatType, nil, true) end
end

local function IsKnown(guid)
	if not guid then return false end
	if C_FriendList and C_FriendList.IsFriend and C_FriendList.IsFriend(guid) then return true end
	if C_BattleNet and C_BattleNet.GetAccountInfoByGUID and C_BattleNet.GetAccountInfoByGUID(guid) then return true end
	if IsGuildMember and IsGuildMember(guid) then return true end
	return false
end

local function OnWhisper(text, sender, _, _, _, flags, _, _, _, _, _, guid)
	if not sender or sender == "" then return end
	lastWhisperer = sender
	lastWhisperAt = GetTime()
	UpdateTitle()
	C_Timer.After(WHISPER_WINDOW + 0.5, UpdateTitle)
	if not DB.autoReply then return end
	if flags == "GM" then return end
	if InCombatLockdown() and IsInInstance() then return end -- chat is restricted there
	if text == DB.note then return end -- another DeckTalk user: no ping-pong
	if DB.replySkipKnown and IsKnown(guid) then return end
	local now = GetTime()
	if replied[sender] and now - replied[sender] < REPLY_COOLDOWN then return end
	replied[sender] = now
	Send(DB.note, "WHISPER", sender, true)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")

ev:SetScript("OnEvent", function(self, event, ...)
	if event == "ADDON_LOADED" then
		if ... ~= ADDON then return end
		DeckTalkDB = DeckTalkDB or {}
		NormalizePhrases(DeckTalkDB)
		DB = CopyDefaults(DEFAULTS, DeckTalkDB)
		CreatePanel()
		self:UnregisterEvent("ADDON_LOADED")
		for _, e in ipairs({ "PLAYER_LOGIN", "GROUP_JOINED", "GROUP_LEFT", "GROUP_ROSTER_UPDATE",
			"CHAT_MSG_WHISPER", "UPDATE_BINDINGS", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED" }) do
			self:RegisterEvent(e)
		end

	elseif event == "PLAYER_LOGIN" then
		if ConsolePort and ConsolePort.AddInterfaceCursorFrame then
			pcall(ConsolePort.AddInterfaceCursorFrame, ConsolePort, panel)
		end
		Layout()
		UpdateTitle()
		if not DB.setupDone then C_Timer.After(2, AutoSetup) end -- first run after install

	elseif event == "GROUP_JOINED" then
		pendingIntro = true
		C_Timer.After(3, TryIntro)
		UpdateTitle()

	elseif event == "GROUP_LEFT" or event == "GROUP_ROSTER_UPDATE" then
		UpdateTitle()

	elseif event == "PLAYER_REGEN_DISABLED" then
		-- fires just before combat lockdown: hand the D-pad / Enter / Esc back to the game
		StopCapture("|cffff5555Combat started.|r Choose the button again afterwards.")
		ReleaseKeys(menu)
		ReleaseKeys(setup)
		RefreshMenu()
		RefreshSetup()

	elseif event == "PLAYER_REGEN_ENABLED" then
		if pendingIntro then C_Timer.After(1, TryIntro) end
		if menu then
			if menu.pendingRelease then ReleaseKeys(menu) end
			if menu:IsShown() then CaptureKeys(menu, MENU_KEYS) RefreshMenu() end
		end
		if setup then
			if setup.pendingRelease then ReleaseKeys(setup) end
			if setup:IsShown() then CaptureKeys(setup, SETUP_KEYS) RefreshSetup() end
		end
		if setupPending then C_Timer.After(1, AutoSetup) end

	elseif event == "UPDATE_BINDINGS" then
		Layout()
		RefreshMenu()

	elseif event == "CHAT_MSG_WHISPER" then
		-- pcall: chat payloads can be "secret" values in restricted situations
		pcall(OnWhisper, ...)
	end
end)

---------------------------------------------------------------------------
-- Slash commands & binding labels
---------------------------------------------------------------------------
BINDING_HEADER_DECKTALK = "DeckTalk"
BINDING_NAME_DECKTALK_MENU = "Quick chat menu (press again: next)"
BINDING_NAME_DECKTALK_MENU_SEND = "Quick chat: send selected"
BINDING_NAME_DECKTALK_TOGGLE = "Show / hide panel"
BINDING_NAME_DECKTALK_LFG = "LFG for tracked quest"
BINDING_NAME_DECKTALK_NOTE = "Send my note"
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
	elseif cmd == "setup" then
		OpenSetup()
	elseif cmd == "scale" and tonumber(rest) then
		DB.scale = math.max(0.5, math.min(2, tonumber(rest)))
		panel:SetScale(DB.scale)
		SavePosition()
	elseif cmd == "reset" then
		DB.pos = nil
		panel:ClearAllPoints()
		panel:SetPoint("LEFT", UIParent, "LEFT", 16, 80)
	else
		Print("/dt - show/hide panel | /dt setup | /dt config - edit texts | /dt scale 0.9 | /dt reset")
	end
end
