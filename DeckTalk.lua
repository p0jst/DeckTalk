-- DeckTalk: one-tap chat for Steam Deck / controller players
-- Works on WoW: Forever and retail (both run the modern client).
local ADDON = ...

---------------------------------------------------------------------------
-- Defaults
---------------------------------------------------------------------------
local NUM_PHRASES = 8
local DEFAULTS = {
	phrases = {
		{ label = "Hi!",         text = "Hi!" },
		{ label = "Thanks!",     text = "Thanks!" },
		{ label = "Yes",         text = "Yes" },
		{ label = "No",          text = "No" },
		{ label = "One sec",     text = "One sec please." },
		{ label = "Sorry!",      text = "Sorry!" },
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

-- %q quest  %t target  %z zone  %w role+level+class  %r role  %l level  %c class
local function Expand(msg, questFallback)
	msg = msg:gsub("%%q", function() return GetQuestText() or questFallback or "this quest" end)
	msg = msg:gsub("%%t", function() return (UnitName("target")) or "" end)
	msg = msg:gsub("%%z", function() return GetZoneText() or "" end)
	msg = msg:gsub("%%w", function() return WhoText() end)
	msg = msg:gsub("%%r", function() local r = GetRole() return r and ROLE_TEXT[r] or "" end)
	msg = msg:gsub("%%l", function() return tostring(UnitLevel("player") or "") end)
	msg = msg:gsub("%%c", function() return (UnitClass("player")) or "" end)
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
	return GroupChatType() or "SAY"
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
local panel, titleText
local phraseButtons, destButtons = {}, {}
local lfgButton, noteButton
local OpenEditor, UpdateTitle

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

function DeckTalk_ReplyNote()
	if not DB then return end
	if not lastWhisperer then Print("Nobody has whispered you yet.") return end
	Send(DB.note, "WHISPER", lastWhisperer)
end

local function SetDest(d)
	DB.dest = d
	for _, b in ipairs(destButtons) do
		if b.dest == d then
			b:LockHighlight()
			b:SetText("|cffffffff" .. DEST_TEXT[b.dest] .. "|r")
		else
			b:UnlockHighlight()
			b:SetText("|cff999999" .. DEST_TEXT[b.dest] .. "|r")
		end
	end
	UpdateTitle()
end

function DeckTalk_CycleDest()
	if not DB then return end
	local idx = 1
	for i, d in ipairs(DESTS) do if d == DB.dest then idx = i end end
	SetDest(DESTS[idx % #DESTS + 1])
end

---------------------------------------------------------------------------
-- Main panel
---------------------------------------------------------------------------
local PAD, BTN_W, BTN_H, DEST_H, TITLE_H = 6, 150, 32, 22, 26
local CONTENT_W = BTN_W * 2 + PAD
local FRAME_W = CONTENT_W + PAD * 2
local PHRASE_TOP = TITLE_H + DEST_H + PAD * 2
local FRAME_H = PHRASE_TOP + (NUM_PHRASES / 2 + 1) * (BTN_H + PAD) + PAD

local function KeyText(action)
	local key = GetBindingKey(action)
	if not key then return "" end
	return GetBindingText(key, true) or key
end

-- "Party", "Whisper Bob", or a red warning when the destination can't be used
local function DestLabel()
	local chatType, target = ResolveDest()
	if not chatType then
		return "|cffff5555" .. (DB.dest == "WHISPER" and "no whisper yet" or "not in a group") .. "|r"
	elseif chatType == "WHISPER" then
		local ok, short = pcall(Ambiguate, target, "short")
		return "|cffff80ffWhisper " .. tostring(ok and short or target) .. "|r"
	end
	return CHAT_TEXT[chatType] or chatType
end

local RefreshMenu -- quick chat menu, defined below

function UpdateTitle()
	if titleText then titleText:SetText("DeckTalk  |cff999999to|r " .. DestLabel()) end
	if RefreshMenu then RefreshMenu() end
end

local function UpdateButtons()
	if not panel then return end
	for i = 1, NUM_PHRASES do
		local b, p = phraseButtons[i], DB.phrases[i]
		b.baseText = (p and p.label ~= "") and p.label or ("Phrase " .. i)
		if not b.flashTimer then b:SetText(b.baseText) end
		b.key:SetText(KeyText("DECKTALK_PHRASE" .. i))
	end
	lfgButton.key:SetText(KeyText("DECKTALK_LFG"))
	noteButton.key:SetText(KeyText("DECKTALK_NOTE"))
end

local function SavePosition()
	DB.pos = { panel:GetLeft(), panel:GetTop() }
end

local function ApplyCollapsed()
	local c = DB.collapsed
	for _, child in ipairs(panel.content) do child:SetShown(not c) end
	if panel.Inset then panel.Inset:SetShown(not c) end
	panel:SetHeight(c and TITLE_H + 2 or FRAME_H)
	panel.minBtn:SetText(c and "+" or "-")
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

local function MakeActionButton(col, row, onClick)
	local b = MakeButton(panel, BTN_W, BTN_H,
		PAD + col * (BTN_W + PAD), -PHRASE_TOP - row * (BTN_H + PAD), "", onClick)
	local fs = b:GetFontString()
	if fs then fs:SetWidth(BTN_W - 30) fs:SetWordWrap(false) end -- long labels get "..."
	b.key = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	b.key:SetPoint("TOPRIGHT", -5, -4)
	tinsert(panel.content, b)
	return b
end

local function CreatePanel()
	panel = CreateFrame("Frame", "DeckTalkPanel", UIParent, "BasicFrameTemplateWithInset")
	panel.content = {}
	panel:SetSize(FRAME_W, FRAME_H)
	panel:SetMovable(true)
	panel:EnableMouse(true)
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", panel.StartMoving)
	panel:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() SavePosition() end)
	panel:SetClampedToScreen(true)
	panel:SetScale(DB.scale or 1)
	if panel.CloseButton then panel.CloseButton:Hide() end -- minimize instead of close

	if DB.pos and type(DB.pos[1]) == "number" then
		panel:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", DB.pos[1], DB.pos[2])
	else
		panel:SetPoint("LEFT", UIParent, "LEFT", 16, 80)
	end

	titleText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	titleText:SetPoint("TOPLEFT", 10, -6)
	titleText:SetWidth(FRAME_W - 86) -- leave room for Edit / minimize buttons
	titleText:SetJustifyH("LEFT")
	titleText:SetWordWrap(false)

	panel.minBtn = MakeButton(panel, 22, 18, 0, 0, "-", function()
		DB.collapsed = not DB.collapsed
		ApplyCollapsed()
	end)
	panel.minBtn:ClearAllPoints()
	panel.minBtn:SetPoint("TOPRIGHT", -4, -3)
	AddTooltip(panel.minBtn, function() return DB.collapsed and "Expand" or "Minimize" end)

	local edit = MakeButton(panel, 40, 18, 0, 0, "Edit", function() OpenEditor() end)
	edit:ClearAllPoints()
	edit:SetPoint("RIGHT", panel.minBtn, "LEFT", -2, 0)
	AddTooltip(edit, function() return "Edit phrases and options" end)

	-- destination selector
	local dw = math.floor((CONTENT_W - 3 * 4) / 4)
	for i, d in ipairs(DESTS) do
		local b = MakeButton(panel, dw, DEST_H, PAD + (i - 1) * (dw + 4), -TITLE_H - PAD, DEST_TEXT[d],
			function() SetDest(d) end)
		b.dest = d
		AddTooltip(b, function()
			if d == "AUTO" then return "Group chat when in a group, otherwise /say" end
			if d == "WHISPER" then return "Reply to the last person who whispered you" end
			if d == "GROUP" then return "Party / raid / instance chat" end
			return "/say to players nearby"
		end)
		destButtons[i] = b
		tinsert(panel.content, b)
	end

	for i = 1, NUM_PHRASES do
		local b = MakeActionButton((i - 1) % 2, math.floor((i - 1) / 2), function() DeckTalk_Phrase(i) end)
		AddTooltip(b, function() return Expand(DB.phrases[i].text) end)
		phraseButtons[i] = b
	end

	local row = NUM_PHRASES / 2
	lfgButton = MakeActionButton(0, row, DeckTalk_LFG)
	lfgButton.baseText = "|cff00ff00LFG: quest|r"
	lfgButton:SetText(lfgButton.baseText)
	AddTooltip(lfgButton, function()
		return Expand(DB.lfgFormat, GetZoneText()) .. "\n|cff999999Posted in LookingForGroup (or General)|r"
	end)

	noteButton = MakeActionButton(1, row, DeckTalk_Note)
	noteButton.baseText = "|cffffcc00Deck note|r"
	noteButton:SetText(noteButton.baseText)
	AddTooltip(noteButton, function() return DB.note end)

	SetDest(DB.dest)
	UpdateButtons()
	ApplyCollapsed()
	panel:SetShown(DB.shown)
end

function DeckTalk_Toggle()
	if not panel then return end
	if not panel:IsShown() then
		DB.shown, DB.collapsed = true, false
		panel:Show()
	else
		DB.collapsed = not DB.collapsed
	end
	ApplyCollapsed()
end

-- Addon compartment (retail minimap dropdown): left = toggle, right = settings
function DeckTalk_OnCompartmentClick(_, button)
	if button == "RightButton" then OpenEditor() else DeckTalk_Toggle() end
end

function DeckTalk_OnCompartmentEnter(_, frame)
	GameTooltip:SetOwner(frame, "ANCHOR_LEFT")
	GameTooltip:SetText("DeckTalk")
	GameTooltip:AddLine("Left-click: show / minimize", 1, 1, 1)
	GameTooltip:AddLine("Right-click: edit phrases", 1, 1, 1)
	GameTooltip:Show()
end

function DeckTalk_OnCompartmentLeave()
	GameTooltip:Hide()
end

---------------------------------------------------------------------------
-- Quick chat menu: one bind opens it, D-pad / arrows choose, A / Enter send.
-- Needs no cursor, so it works in WoW: Forever's native Gamepad mode, with
-- ConsolePort, and with Steam Input keyboard mappings alike.
---------------------------------------------------------------------------
local menu
local menuItems, menuSel, menuIdle = {}, 1, nil
local pendingUnbind = false
local MENU_W, ROW_H, MENU_TOP, MENU_FOOT = 320, 30, 34, 58
local MENU_ROWS = NUM_PHRASES + 2
local MENU_IDLE = 12 -- seconds before the menu closes by itself

-- Keys captured only while the menu is open (released again on close / before combat)
local MENU_KEYS = {
	PADDUP = "DeckTalkMenuUp",     UP = "DeckTalkMenuUp",
	PADDDOWN = "DeckTalkMenuDown", DOWN = "DeckTalkMenuDown",
	PAD1 = "DeckTalkMenuSend",     ENTER = "DeckTalkMenuSend",
	PAD2 = "DeckTalkMenuClose",    ESCAPE = "DeckTalkMenuClose",
	PADDLEFT = "DeckTalkMenuLeft", LEFT = "DeckTalkMenuLeft",
	PADDRIGHT = "DeckTalkMenuRight", RIGHT = "DeckTalkMenuRight",
}

local function GamePadOn()
	if C_GamePad and C_GamePad.IsEnabled then
		local ok, on = pcall(C_GamePad.IsEnabled)
		if ok and on then return true end
	end
	return GetCVarBool and GetCVarBool("GamePadEnable") or false
end

local function BuildMenuItems()
	wipe(menuItems)
	for i = 1, NUM_PHRASES do
		local p = DB.phrases[i]
		if p and p.text ~= "" then
			tinsert(menuItems, {
				label = (p.label ~= "" and p.label) or p.text,
				run = function() return DeckTalk_Phrase(i) end,
				preview = function() return Expand(p.text) end,
			})
		end
	end
	tinsert(menuItems, { label = "|cff00ff00LFG: quest|r", run = DeckTalk_LFG,
		preview = function() return Expand(DB.lfgFormat, GetZoneText()) .. "  |cff999999(LFG channel)|r" end })
	tinsert(menuItems, { label = "|cffffcc00Deck note|r", run = DeckTalk_Note,
		preview = function() return DB.note end })
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
	menu.preview:SetText(item and ("|cff999999Sends:|r " .. item.preview()) or "")
	menu.hint:SetText(MenuHint())
	menu:SetHeight(MENU_TOP + #menuItems * ROW_H + MENU_FOOT)
end

local function ReleaseKeys()
	if not menu or not menu.captured then return end
	if InCombatLockdown() then pendingUnbind = true return end
	ClearOverrideBindings(menu)
	menu.captured = false
	pendingUnbind = false
end

local function CaptureKeys()
	if menu.captured or InCombatLockdown() then return end
	for key, button in pairs(MENU_KEYS) do
		SetOverrideBindingClick(menu, true, key, button)
	end
	menu.captured = true
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

	-- invisible buttons the captured keys "click" (key presses count as hardware events)
	local actions = {
		DeckTalkMenuUp = function() MenuMove(-1) end,
		DeckTalkMenuDown = function() MenuMove(1) end,
		DeckTalkMenuSend = MenuSend,
		DeckTalkMenuClose = function() menu:Hide() end,
		DeckTalkMenuLeft = function() MenuDest(-1) end,
		DeckTalkMenuRight = function() MenuDest(1) end,
	}
	for name, fn in pairs(actions) do
		local b = CreateFrame("Button", name, menu)
		b:SetSize(1, 1)
		b:SetScript("OnClick", fn)
	end

	menu:SetScript("OnHide", function()
		if menuIdle then menuIdle:Cancel() menuIdle = nil end
		ReleaseKeys()
	end)

	if ConsolePort and ConsolePort.AddInterfaceCursorFrame then
		pcall(ConsolePort.AddInterfaceCursorFrame, ConsolePort, menu)
	end
end

-- Bind 1: open, or move to the next entry when already open
function DeckTalk_QuickMenu()
	if not DB then return end
	if not menu then CreateMenu() end
	if menu:IsShown() then MenuMove(1) return end
	BuildMenuItems()
	menu:Show()
	CaptureKeys()
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
local EDITOR_W, EDITOR_H = 520, 572

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
	editor.skipKnown:SetChecked(src.replySkipKnown)
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
	Label(editor, "Message", 135, -32)

	local order = {}
	editor.labels, editor.texts = {}, {}
	for i = 1, NUM_PHRASES do
		local y = -46 - (i - 1) * 28
		editor.labels[i] = MakeEdit(editor, 100, 24, y, 16)
		editor.texts[i]  = MakeEdit(editor, 360, 137, y)
		tinsert(order, editor.labels[i])
		tinsert(order, editor.texts[i])
	end

	Label(editor, "Steam Deck note", 22, -276)
	editor.note = MakeEdit(editor, 473, 24, -290)
	Label(editor, "LFG message", 22, -318)
	editor.lfg = MakeEdit(editor, 473, 24, -332)
	tinsert(order, editor.note)
	tinsert(order, editor.lfg)

	editor.preview = Label(editor, "", 22, -358, "GameFontHighlightSmall")
	editor.preview:SetWidth(EDITOR_W - 44)
	editor.preview:SetWordWrap(false)
	editor.lfg:SetScript("OnTextChanged", UpdatePreview)

	local help = Label(editor,
		"Placeholders: %q tracked quest   %t target   %z zone\n" ..
		"%w role + level + class   %r role   %l level   %c class", 22, -376, "GameFontDisableSmall")
	help:SetWidth(EDITOR_W - 44)

	-- Tab / Shift-Tab between fields
	for i, e in ipairs(order) do
		e:SetScript("OnTabPressed", function(self)
			self:ClearFocus()
			local step = IsShiftKeyDown() and -1 or 1
			order[(i - 1 + step) % #order + 1]:SetFocus()
		end)
	end

	editor.roleBtn = MakeButton(editor, 200, 22, 22, -408, "", function(self)
		local idx = 1
		for i, r in ipairs(ROLE_CYCLE) do if r == editor.role then idx = i end end
		editor.role = ROLE_CYCLE[idx % #ROLE_CYCLE + 1]
		self:SetText(RoleButtonText(editor.role))
		UpdatePreview()
	end)
	Label(editor, "Click to change. Auto uses your current spec.", 230, -414, "GameFontDisableSmall")

	editor.autoIntro = MakeCheck(editor, "Post my note in group chat when I join a group", 18, -440)
	editor.autoReply = MakeCheck(editor, "Auto-whisper my note back (once per player per 10 min)", 18, -466)
	editor.skipKnown = MakeCheck(editor, "...but not to friends or guild members", 40, -492)

	local save = MakeButton(editor, 110, 26, 0, 0, "Save", function()
		for i = 1, NUM_PHRASES do
			DB.phrases[i].label = editor.labels[i]:GetText()
			DB.phrases[i].text  = editor.texts[i]:GetText()
		end
		DB.note           = editor.note:GetText()
		DB.lfgFormat      = editor.lfg:GetText()
		DB.role           = editor.role
		DB.autoIntro      = editor.autoIntro:GetChecked()
		DB.autoReply      = editor.autoReply:GetChecked()
		DB.replySkipKnown = editor.skipKnown:GetChecked()
		UpdateButtons()
		editor:Hide()
		Print("Saved.")
	end)
	save:ClearAllPoints()
	save:SetPoint("BOTTOMRIGHT", -14, 12)

	local cancel = MakeButton(editor, 110, 26, 0, 0, "Cancel", function() editor:Hide() end)
	cancel:ClearAllPoints()
	cancel:SetPoint("RIGHT", save, "LEFT", -8, 0)

	local defaults = MakeButton(editor, 110, 26, 0, 0, "Defaults", function()
		FillEditor(DEFAULTS)
		Print("Defaults loaded into the editor - press Save to keep them.")
	end)
	defaults:ClearAllPoints()
	defaults:SetPoint("BOTTOMLEFT", 14, 12)

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
	UpdateTitle()
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
		DeckTalkDB = CopyDefaults(DEFAULTS, DeckTalkDB or {})
		DB = DeckTalkDB
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
		UpdateButtons()
		UpdateTitle()

	elseif event == "GROUP_JOINED" then
		pendingIntro = true
		C_Timer.After(3, TryIntro)
		UpdateTitle()

	elseif event == "GROUP_LEFT" or event == "GROUP_ROSTER_UPDATE" then
		UpdateTitle()

	elseif event == "PLAYER_REGEN_DISABLED" then
		-- fires just before combat lockdown: hand the D-pad / Enter / Esc back to the game
		ReleaseKeys()
		RefreshMenu()

	elseif event == "PLAYER_REGEN_ENABLED" then
		if pendingIntro then C_Timer.After(1, TryIntro) end
		if pendingUnbind then ReleaseKeys() end
		if menu and menu:IsShown() then CaptureKeys() RefreshMenu() end

	elseif event == "UPDATE_BINDINGS" then
		UpdateButtons()
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
BINDING_NAME_DECKTALK_TOGGLE = "Show / minimize panel"
BINDING_NAME_DECKTALK_LFG = "LFG for tracked quest"
BINDING_NAME_DECKTALK_NOTE = "Send Steam Deck note"
BINDING_NAME_DECKTALK_REPLY = "Whisper note to last whisperer"
BINDING_NAME_DECKTALK_DEST = "Cycle destination (Auto/Say/Group/Whisper)"
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
	elseif cmd == "hide" then
		DB.shown = false
		panel:Hide()
	elseif cmd == "show" then
		DB.shown, DB.collapsed = true, false
		panel:Show()
		ApplyCollapsed()
	elseif cmd == "scale" and tonumber(rest) then
		DB.scale = math.max(0.5, math.min(2, tonumber(rest)))
		panel:SetScale(DB.scale)
		SavePosition()
	elseif cmd == "reset" then
		DB.pos = nil
		panel:ClearAllPoints()
		panel:SetPoint("LEFT", UIParent, "LEFT", 16, 80)
	else
		Print("/dt - show/minimize | /dt config | /dt hide | /dt show | /dt scale 1.2 | /dt reset")
	end
end
