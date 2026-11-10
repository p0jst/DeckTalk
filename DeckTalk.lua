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
local function SendToDest(text, btn)
	local chatType, target, reason = ResolveDest()
	if not chatType then Print(reason) return end
	if Send(text, chatType, target) then Flash(btn) end
end

function DeckTalk_Phrase(i)
	if not DB then return end
	local p = DB.phrases[i]
	if p and p.text ~= "" then SendToDest(p.text, phraseButtons[i]) end
end

function DeckTalk_Note()
	if DB then SendToDest(DB.note, noteButton) end
end

function DeckTalk_LFG()
	if not DB then return end
	-- no tracked quest -> "LFG <zone> - Healer, lvl 18 Druid"
	local msg = Expand(DB.lfgFormat, GetZoneText())
	local chan = FindLFGChannel()
	local ok
	if chan then ok = Send(msg, "CHANNEL", chan) else ok = Send(msg, "SAY") end
	if ok then Flash(lfgButton) end
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

function UpdateTitle()
	if not titleText then return end
	local chatType, target = ResolveDest()
	local where
	if not chatType then
		where = "|cffff5555" .. (DB.dest == "WHISPER" and "no whisper yet" or "not in a group") .. "|r"
	elseif chatType == "WHISPER" then
		local ok, short = pcall(Ambiguate, target, "short")
		where = "|cffff80ffWhisper " .. tostring(ok and short or target) .. "|r"
	else
		where = CHAT_TEXT[chatType] or chatType
	end
	titleText:SetText("DeckTalk  |cff999999to|r " .. where)
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
			"CHAT_MSG_WHISPER", "UPDATE_BINDINGS", "PLAYER_REGEN_ENABLED" }) do
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

	elseif event == "PLAYER_REGEN_ENABLED" then
		if pendingIntro then C_Timer.After(1, TryIntro) end

	elseif event == "UPDATE_BINDINGS" then
		UpdateButtons()

	elseif event == "CHAT_MSG_WHISPER" then
		-- pcall: chat payloads can be "secret" values in restricted situations
		pcall(OnWhisper, ...)
	end
end)

---------------------------------------------------------------------------
-- Slash commands & binding labels
---------------------------------------------------------------------------
BINDING_HEADER_DECKTALK = "DeckTalk"
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
