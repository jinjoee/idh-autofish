-- Indo Hangout Auto-Fishing v1 (cautious: plays the minigame for real)
-- Game: Indo Hangout | Place 9788848685
-- How it works (mirrors RodLocalScript + ReelingLocalScript exactly):
--   1. tool:Activate() -> Rod:FireServer("Throw") (real tool activation, 1s debounce kept)
--   2. server eventually sends ("StartReeling", tool) -> Reeling GUI enables
--   3. minigame: hold (Mouse/Space) moves WhiteBar RIGHT 0.48/s, release moves LEFT.
--      Keep WhiteBar overlapping RedBar -> ProgressBar fills -> server sends catch.
--      We press/release SPACE via VirtualInputManager = genuine input events,
--      identical to a player holding space. Nothing is spoofed server-side:
--      catch timing is whatever skilled play produces.
-- Anti-cheat posture: no remote spam (only the game's own Throw/Catch fire via
-- normal code paths), no teleport, no speedhack, human-like pauses + breaks.
-- Worst case this looks like a very focused player. Use at your own risk.

local PLACE_ID = 9788848685
if game.PlaceId ~= PLACE_ID then
	print("[AutoFish] wrong game, refusing to run.")
	return
end

getgenv().IndoAutoFish = getgenv().IndoAutoFish or {}
local CFG = getgenv().IndoAutoFish
CFG.Gen = (CFG.Gen or 0) + 1
local GEN = CFG.Gen
CFG.Enabled = true -- getgenv().IndoAutoFish.Enabled = false to stop
CFG.RodName = CFG.RodName or "Basic Rod" -- which tool to fish with
CFG.BiteTimeout = CFG.BiteTimeout or 45 -- re-throw if no bite in Ns
CFG.PauseMin = CFG.PauseMin or 1.5 -- human pause between casts
CFG.PauseMax = CFG.PauseMax or 3.5
CFG.BreakEvery = CFG.BreakEvery or 25 -- longer "stretch" break every N catches
CFG.BreakMin = CFG.BreakMin or 8
CFG.BreakMax = CFG.BreakMax or 20
CFG.Deadband = CFG.Deadband or 0.004 -- how close to center before releasing
CFG.Stats = CFG.Stats or {casts = 0, catches = 0, misses = 0, sold = 0, earned = ""}
-- KEY SYSTEM, v2 (daily keys, 24h windows):
-- The script accepts: your MASTER_KEY (never expires, only for you) or
-- TODAY's / YESTERDAY's derived key (UTC). Keys look like
-- "6a97588d2e2a92141b64257975b542a4" and change every midnight UTC.
-- Flow: friend finishes your Linkvertise/Work.ink steps -> lands on your key
-- page (Pastebin/Discord pinned) where you post today's key -> pastes it in.
-- Same honesty as before: the SECRET below is readable in this public file,
-- so a determined reader could re-derive keys. This stops casual sharing
-- and powers the link-monetization loop; true per-user HWID keys need a
-- key server. Change SECRET + MASTER_KEY, then tell me to repush.
local KEY_SECRET = "IDH-9f2K7qZ3mX8"
local MASTER_KEY = "jinjoee-owner-7x2q"
local function djb2(s, seed)
	local h = seed
	for i = 1, #s do
		h = (h * 33 + string.byte(s, i)) % 4294967296
	end
	return h
end
local function hex8(n)
	local digits = "0123456789abcdef"
	local out = ""
	for _ = 1, 8 do
		local d = n % 16
		out = string.sub(digits, d + 1, d + 1) .. out
		n = math.floor(n / 16)
	end
	return out
end
local function dailyKey(dateStr)
	local parts = ""
	local seeds = {5381, 2443, 7919, 104729}
	for r = 1, 4 do
		parts = parts .. hex8(djb2(KEY_SECRET .. "|" .. dateStr .. "|" .. r, seeds[r]))
	end
	return parts -- 32 hex chars, e.g. 6a97588d...
end
local function utcDate(offsetDays)
	local t = os.date("!*t", os.time() + (offsetDays or 0) * 86400)
	return string.format("%04d-%02d-%02d", t.year, t.month, t.day)
end
local function validKey(v)
	if v == MASTER_KEY then return true, "master" end
	if v == dailyKey(utcDate(0)) then return true, "today" end
	if v == dailyKey(utcDate(-1)) then return true, "yesterday" end -- timezone grace
	return false
end
getgenv().IndoAutoFish_CheckKey = function(k) return validKey(tostring(k or "")) end
CFG.Unlocked = false -- always ask on each execute
CFG.AutoSell = (CFG.AutoSell == nil) and true or CFG.AutoSell
CFG.SellEvery = CFG.SellEvery or 10 -- sell after this many new catches
CFG.SellAt = CFG.SellAt or 15 -- sell when bag holds this many fish (no hard cap found: 17 tools seen fine, so this is YOUR cap)
CFG.SellFilter = CFG.SellFilter or "Sell All" -- "Sell All" | "All under 50 Kg" | ... (keeps trophies if filtered)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer
local VIM = nil
pcall(function() VIM = game:GetService("VirtualInputManager") end)

-- Anti-AFK: Roblox kicks after 20 min without REAL input. Our VIM Space
-- presses and the camera shake do NOT reset that timer (synthetic in-game
-- input doesn't count). VirtualUser clicks DO — this is the standard,
-- traffic-free bypass: no remotes, no movement, just presence.
pcall(function()
	local VU = game:GetService("VirtualUser")
	LocalPlayer.Idled:Connect(function()
		pcall(function()
			VU:CaptureController()
			VU:ClickButton2(Vector2.new())
		end)
	end)
end)

local function gui()
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local r = pg and pg:FindFirstChild("Reeling")
	if not r then return nil end
	local main = r:FindFirstChild("MainFrame")
	local frame = main and main:FindFirstChild("Frame")
	local prog = main and main:FindFirstChild("ProgressBg")
	if not (frame and prog) then return nil end
	return {
		root = r,
		white = frame:FindFirstChild("WhiteBar"),
		red = frame:FindFirstChild("RedBar"),
		prog = prog:FindFirstChild("ProgressBar"),
	}
end

local function barSpan(bar)
	-- mirrors isTouching(): left edge, right edge in X.Scale
	local l = bar.Position.X.Scale - bar.Size.X.Scale * bar.AnchorPoint.X
	return l, l + bar.Size.X.Scale
end

local function isTouching(g)
	local wl, wr = barSpan(g.white)
	local rl, rr = barSpan(g.red)
	return rl < wr and wl < rr
end

local holding = false
local function setHold(v)
	if v == holding then return end
	holding = v
	if VIM then
		pcall(function()
			VIM:SendKeyEvent(v, Enum.KeyCode.Space, false, game)
		end)
	end
end

local function findRod()
	local char = LocalPlayer.Character
	if char then
		local t = char:FindFirstChild(CFG.RodName)
		if t and t:IsA("Tool") then return t, true end
		for _, t in ipairs(char:GetChildren()) do
			if t:IsA("Tool") and string.find(string.lower(t.Name), "rod", 1, true) then
				return t, true
			end
		end
	end
	local bp = LocalPlayer:FindFirstChildOfClass("Backpack")
	if bp then
		local t = bp:FindFirstChild(CFG.RodName)
		if t and t:IsA("Tool") then return t, false end
		for _, t in ipairs(bp:GetChildren()) do
			if t:IsA("Tool") and string.find(string.lower(t.Name), "rod", 1, true) then
				return t, false
			end
		end
	end
	return nil, false
end

-- Minigame driver: track RedBar center with WhiteBar, 60Hz.
task.spawn(function()
	while GEN == CFG.Gen and not CFG.Unlocked do task.wait(0.5) end
	while GEN == CFG.Gen do
		task.wait(1 / 60)
		if not CFG.Enabled then
			if holding then setHold(false) end
			continue
		end
		local g = gui()
		if not g or not g.root.Enabled then
			if holding then setHold(false) end
			continue
		end
		local ok, wl, wr, rl, rr = pcall(function()
			local a, b = barSpan(g.white)
			local c, d = barSpan(g.red)
			return a, b, c, d
		end)
		if not ok then continue end
		local wc = (wl + wr) / 2
		local rc = (rl + rr) / 2
		if wc < rc - CFG.Deadband then
			setHold(true) -- WhiteBar left of target: hold -> moves right
		elseif wc > rc + CFG.Deadband then
			setHold(false) -- overshooting: release -> drifts left
		end
		-- inside deadband: keep current state (no flutter)
	end
end)

-- Auto-sell: same two invokes the Sell buttons make (CheckFish then SellFish).
-- Verified working with no NPC-proximity gate. Runs rarely (every SellEvery
-- catches or when the bag hits SellAt), so traffic looks like shop visits.
local function fishCount()
	local n = 0
	local bp = LocalPlayer:FindFirstChildOfClass("Backpack")
	if bp then
		for _, t in ipairs(bp:GetChildren()) do
			if t:IsA("Tool") and string.find(string.lower(t.Name), "ikan", 1, true) then
				n = n + 1
			end
		end
	end
	return n
end

local function autoSell(why)
	if not CFG.AutoSell and why ~= "now" then return end
	local ok, rf = pcall(function()
		return ReplicatedStorage.Events.RemoteFunction.SellFish
	end)
	if not ok or not rf then return end
	local cash, bonus, count
	local ok2 = pcall(function()
		cash, bonus, count = rf:InvokeServer("CheckFish", CFG.SellFilter)
	end)
	if not ok2 or not (cash and count) then return end
	if tonumber(count) == nil or tonumber(count) <= 0 then return end
	print(("[AutoFish] selling %s fish (~Rp %s)"):format(tostring(count), tostring(cash)))
	pcall(function() rf:InvokeServer("SellFish", CFG.SellFilter) end)
	CFG.Stats.sold = CFG.Stats.sold + (tonumber(count) or 0)
	CFG.Stats.earned = tostring(cash)
end

-- Cast loop: equip -> throw -> wait for bite/GUI end -> pause -> repeat.
task.spawn(function()
	while GEN == CFG.Gen and not CFG.Unlocked do task.wait(0.5) end
	while GEN == CFG.Gen do
		if not CFG.Enabled then task.wait(0.5) continue end
		local rod, equipped = findRod()
		if not rod then
			warn("[AutoFish] no rod found, retrying in 5s")
			task.wait(5)
			continue
		end
		if not equipped then
			pcall(function() LocalPlayer.Character:FindFirstChildOfClass("Humanoid"):EquipTool(rod) end)
			task.wait(0.6)
		end
		-- don't cast while a minigame is already running
		local g0 = gui()
		if g0 and g0.root.Enabled then task.wait(1) continue end

		CFG.Stats.casts = CFG.Stats.casts + 1
		local n = CFG.Stats.casts
		pcall(function() rod:Activate() end) -- real activation -> "Throw", game's own debounce applies
		print("[AutoFish] cast #" .. n)

		-- wait for bite (GUI enables) or timeout
		local t0 = os.clock()
		local bit = false
		while GEN == CFG.Gen and CFG.Enabled and os.clock() - t0 < CFG.BiteTimeout do
			local g = gui()
			if g and g.root.Enabled then bit = true break end
			task.wait(0.5)
		end
		if not bit then
			print("[AutoFish] no bite, re-casting")
			task.wait(1)
			continue
		end
		-- minigame running: wait until GUI closes (Catch or Miss), track PEAK
		-- progress (the final jump to 1.0 happens between 0.5s samples)
		local pmax = 0
		while GEN == CFG.Gen and CFG.Enabled do
			local g = gui()
			if not g or not g.root.Enabled then break end
			pcall(function() pmax = math.max(pmax, g.prog.Size.X.Scale) end)
			task.wait(0.2)
		end
		setHold(false)
		task.wait(0.8) -- let Catch/Miss resolve server-side
		if pmax >= 0.99 then CFG.Stats.catches = CFG.Stats.catches + 1
		else CFG.Stats.misses = CFG.Stats.misses + 1 end
		print(("[AutoFish] done (catches=%d misses=%d)"):format(CFG.Stats.catches, CFG.Stats.misses))

		if CFG.AutoSell and CFG.SellEvery > 0 and CFG.Stats.catches > 0
			and CFG.Stats.catches % CFG.SellEvery == 0 then
			task.spawn(function() autoSell("count") end)
		elseif CFG.AutoSell and fishCount() >= CFG.SellAt then
			task.spawn(function() autoSell("full") end)
		end

		if CFG.BreakEvery > 0 and (CFG.Stats.catches + CFG.Stats.misses) % CFG.BreakEvery == 0 then
			local br = CFG.BreakMin + math.random() * (CFG.BreakMax - CFG.BreakMin)
			print(("[AutoFish] break %.0fs"):format(br))
			local t1 = os.clock()
			while GEN == CFG.Gen and os.clock() - t1 < br do task.wait(1) end
		else
			task.wait(CFG.PauseMin + math.random() * (CFG.PauseMax - CFG.PauseMin))
		end
	end
	setHold(false)
end)

print("[AutoFish] v1 loaded. Stop: getgenv().IndoAutoFish.Enabled = false")
print("[AutoFish] VIM (real input): " .. tostring(VIM ~= nil))

-- Control panel: toggles + sell filter. No rarity data exists on fish
-- (tools carry name+weight only), so the server's own weight filters double
-- as the rarity proxy: light fish = common, heavy = valuable.
local SELL_OPTIONS = {"Sell All", "All under 50 Kg", "All under 100 Kg", "All under 400 Kg", "All under 600 Kg", "Sell this fish"}

task.spawn(function()
	local pg = LocalPlayer:WaitForChild("PlayerGui")
	local old = pg:FindFirstChild("IndoAutoFishUI")
	if old then old:Destroy() end

	local gui = Instance.new("ScreenGui")
	gui.Name = "IndoAutoFishUI"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 999
	gui.Enabled = false -- key gate: shown only after unlock
	gui.Parent = pg

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.new(0, 230, 0, 300)
	panel.Position = UDim2.new(0, 12, 0.35, 0)
	panel.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
	panel.BackgroundTransparency = 0.1
	panel.BorderSizePixel = 0
	panel.Active = true
	panel.Parent = gui
	Instance.new("UICorner").Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(70, 78, 95)
	stroke.Transparency = 0.4
	stroke.Parent = panel

	local function label(text, y, h)
		local l = Instance.new("TextLabel")
		l.Size = UDim2.new(1, -16, 0, h or 22)
		l.Position = UDim2.new(0, 8, 0, y)
		l.BackgroundTransparency = 1
		l.TextColor3 = Color3.fromRGB(235, 235, 235)
		l.TextSize = 14
		l.Font = Enum.Font.GothamBold
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.Text = text
		l.Parent = panel
		return l
	end

	local function button(text, y)
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(1, -16, 0, 40) -- 40px touch target
		b.Position = UDim2.new(0, 8, 0, y)
		b.BackgroundColor3 = Color3.fromRGB(45, 50, 62)
		b.TextColor3 = Color3.fromRGB(255, 255, 255)
		b.TextSize = 14
		b.Font = Enum.Font.Gotham
		b.Text = text
		b.AutoButtonColor = true
		b.Parent = panel
		Instance.new("UICorner").Parent = b
		return b
	end

	label("INDO AUTOFISH", 8, 26)
	local titleLbl = panel:FindFirstChildOfClass("TextLabel")
	titleLbl.Active = true -- drag handle
	local fishBtn = button("", 38)
	fishBtn.Name = "FishToggle"
	local sellBtn = button("", 82)
	sellBtn.Name = "SellToggle"
	local filterBtn = button("", 126)
	filterBtn.Name = "FilterButton"
	local sellNowBtn = button("Sell Now", 170)
	sellNowBtn.Name = "SellNow"
	sellNowBtn.Size = UDim2.new(1, -16, 0, 36)
	-- threshold stepper: [-] [N fish] [+]
	local minusBtn = Instance.new("TextButton")
	minusBtn.Name = "ThreshMinus"
	minusBtn.Size = UDim2.new(0, 52, 0, 36)
	minusBtn.Position = UDim2.new(0, 8, 0, 210)
	minusBtn.BackgroundColor3 = Color3.fromRGB(45, 50, 62)
	minusBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	minusBtn.TextSize = 20
	minusBtn.Font = Enum.Font.GothamBold
	minusBtn.Text = "-"
	minusBtn.Parent = panel
	Instance.new("UICorner").Parent = minusBtn
	local threshLbl = Instance.new("TextLabel")
	threshLbl.Name = "ThreshLbl"
	threshLbl.Size = UDim2.new(1, -128, 0, 36)
	threshLbl.Position = UDim2.new(0, 64, 0, 210)
	threshLbl.BackgroundTransparency = 1
	threshLbl.TextColor3 = Color3.fromRGB(235, 235, 235)
	threshLbl.TextSize = 13
	threshLbl.Font = Enum.Font.Gotham
	threshLbl.Text = ""
	threshLbl.Parent = panel
	local plusBtn = Instance.new("TextButton")
	plusBtn.Name = "ThreshPlus"
	plusBtn.Size = UDim2.new(0, 52, 0, 36)
	plusBtn.Position = UDim2.new(1, -60, 0, 210)
	plusBtn.BackgroundColor3 = Color3.fromRGB(45, 50, 62)
	plusBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	plusBtn.TextSize = 20
	plusBtn.Font = Enum.Font.GothamBold
	plusBtn.Text = "+"
	plusBtn.Parent = panel
	Instance.new("UICorner").Parent = plusBtn
	local statsLbl = label("", 250, 44)
	statsLbl.TextYAlignment = Enum.TextYAlignment.Top
	statsLbl.TextSize = 12
	statsLbl.Font = Enum.Font.Gotham

	-- dropdown list (overlays stats while open; closes on pick)
	local paint -- forward: option buttons call it before its definition
	local dropList = Instance.new("Frame")
	dropList.Name = "DropList"
	dropList.Size = UDim2.new(1, -16, 0, #SELL_OPTIONS * 44)
	dropList.Position = UDim2.new(0, 8, 0, 168)
	dropList.BackgroundColor3 = Color3.fromRGB(30, 33, 42)
	dropList.BorderSizePixel = 0
	dropList.Visible = false
	dropList.ZIndex = 50
	dropList.Active = true -- receives taps anywhere inside (fat-finger proof)
	dropList.Parent = panel
	Instance.new("UICorner").Parent = dropList
	-- full-screen invisible veil: outside-tap closes the list
	local veil = Instance.new("TextButton")
	veil.Name = "Veil"
	veil.Size = UDim2.new(1, 0, 1, 0)
	veil.BackgroundTransparency = 1
	veil.Text = ""
	veil.Visible = false
	veil.ZIndex = 40
	veil.Parent = gui
	-- single selection path for row taps AND tap router (with flash feedback)
	local function select(idx, src)
		idx = math.clamp(idx, 1, #SELL_OPTIONS)
		CFG.SellFilter = SELL_OPTIONS[idx]
		CFG._lastOpt = SELL_OPTIONS[idx] .. " via " .. tostring(src)
		dropList.Visible = false
		veil.Visible = false
		paint()
		task.spawn(function()
			filterBtn.BackgroundColor3 = Color3.fromRGB(60, 140, 80)
			task.wait(0.25)
			pcall(paint)
		end)
	end
	local function openList()
		-- refresh checkmarks then show
		for _, ob in ipairs(dropList:GetChildren()) do
			if ob:IsA("TextButton") and ob.Name:match("^Opt%d+$") then
				local n = tonumber(ob.Name:sub(4))
				ob.Text = ((SELL_OPTIONS[n] == CFG.SellFilter) and "[x] " or "[ ] ") .. SELL_OPTIONS[n]
			end
		end
		dropList.Visible = true
		veil.Visible = true
		paint()
	end
	for i, opt in ipairs(SELL_OPTIONS) do
		local ob = Instance.new("TextButton")
		ob.Size = UDim2.new(1, -8, 0, 36)
		ob.Position = UDim2.new(0, 4, 0, (i - 1) * 44 + 4)
		ob.BackgroundColor3 = Color3.fromRGB(55, 60, 74)
		ob.TextColor3 = Color3.fromRGB(255, 255, 255)
		ob.TextSize = 15
		ob.Font = Enum.Font.Gotham
		ob.Text = opt
		ob.Name = "Opt" .. i
		ob.ZIndex = 51
		ob.Parent = dropList
		Instance.new("UICorner").Parent = ob
		local idx = i
		ob.Activated:Connect(function()
			select(idx, "row")
		end)
	end
	-- single tap router: any tap in the list selects the nearest row.
	-- (per-button closures proved unreliable; this can't miss.)
	dropList.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local y = nil
		pcall(function()
			local rel = dropList.AbsolutePosition
			y = input.Position.Y - rel.Y
		end)
		if not y then return end
		select(math.floor(y / 44) + 1, "router")
	end)

	paint = function()
		if not panel.Parent then return end
		fishBtn.Text = "AutoFish: " .. (CFG.Enabled and "ON" or "OFF")
		fishBtn.BackgroundColor3 = CFG.Enabled and Color3.fromRGB(32, 120, 60) or Color3.fromRGB(120, 40, 40)
		sellBtn.Text = "AutoSell: " .. (CFG.AutoSell and "ON" or "OFF")
		sellBtn.BackgroundColor3 = CFG.AutoSell and Color3.fromRGB(32, 120, 60) or Color3.fromRGB(120, 40, 40)
		filterBtn.Text = "Sell: " .. tostring(CFG.SellFilter) .. (dropList.Visible and " [^]" or " [v]")
		threshLbl.Text = "at " .. tostring(CFG.SellAt) .. " fish"
		local s = CFG.Stats
		statsLbl.Text = ("Casts %d\nCatch %d  Miss %d\nSold %d (%s)"):format(
			s.casts, s.catches, s.misses, s.sold, tostring(s.earned))
	end

	fishBtn.Activated:Connect(function()
		CFG.Enabled = not CFG.Enabled
		if not CFG.Enabled then setHold(false) end
		paint()
	end)
	sellBtn.Activated:Connect(function()
		CFG.AutoSell = not CFG.AutoSell
		paint()
	end)
	sellNowBtn.Activated:Connect(function()
		task.spawn(function() autoSell("now") end)
	end)
	minusBtn.Activated:Connect(function()
		CFG.SellAt = math.clamp((tonumber(CFG.SellAt) or 15) - 1, 1, 99)
		paint()
	end)
	plusBtn.Activated:Connect(function()
		CFG.SellAt = math.clamp((tonumber(CFG.SellAt) or 15) + 1, 1, 99)
		paint()
	end)
	filterBtn.Activated:Connect(function()
		if dropList.Visible then
			dropList.Visible = false
			veil.Visible = false
			pcall(paint)
		else
			openList()
		end
	end)
	veil.Activated:Connect(function()
		dropList.Visible = false
		veil.Visible = false
		pcall(paint)
	end)

	-- drag ONLY from the title bar (buttons keep their taps)
	local dragging, dragStart, startPos = false, nil, nil
	CFG._taps = CFG._taps or {}
	panel.InputBegan:Connect(function(input)
		local t = tostring(input.UserInputType)
		CFG._taps[t] = (CFG._taps[t] or 0) + 1
	end)
	titleLbl.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = panel.Position
		end
	end)
	game:GetService("UserInputService").InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - dragStart
			panel.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
				startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
	game:GetService("UserInputService").InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	paint()
	task.spawn(function()
		while GEN == CFG.Gen do
			task.wait(1)
			pcall(paint)
		end
		if gui.Parent then gui:Destroy() end
	end)

	-- event-driven keep-alive: the moment the game hides GUIs for a minigame,
	-- restore only ours (polling races the hide; the signal doesn't).
	pcall(function()
		local reel = pg:FindFirstChild("Reeling")
		if reel then
			reel:GetPropertyChangedSignal("Enabled"):Connect(function()
				if GEN ~= CFG.Gen then return end
				if reel.Enabled then
					task.wait(0.3)
					if GEN == CFG.Gen and gui.Parent and CFG.Unlocked then
						gui.Enabled = true
						pcall(paint)
					end
				end
			end)
			if reel.Enabled and not gui.Enabled then gui.Enabled = true end
		end
	end)
end)

-- KEY PROMPT: first thing the user sees. Main UI + loops wait on CFG.Unlocked.
task.spawn(function()
	while GEN == CFG.Gen and CFG.Unlocked do task.wait(0.5) end
	if GEN ~= CFG.Gen or CFG.Unlocked then return end
	local pg = LocalPlayer:WaitForChild("PlayerGui")
	local old = pg:FindFirstChild("IndoFishKeyUI")
	if old then old:Destroy() end

	local gui = Instance.new("ScreenGui")
	gui.Name = "IndoFishKeyUI"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 1000
	gui.Parent = pg

	local box = Instance.new("Frame")
	box.Name = "KeyBox"
	box.Size = UDim2.new(0, 260, 0, 218)
	box.Position = UDim2.new(0.5, -130, 0.4, 0)
	box.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
	box.BackgroundTransparency = 0.08
	box.BorderSizePixel = 0
	box.Active = true
	box.Draggable = true
	box.Parent = gui
	Instance.new("UICorner").Parent = box
	local st = Instance.new("UIStroke")
	st.Color = Color3.fromRGB(70, 78, 95)
	st.Transparency = 0.4
	st.Parent = box

	local function txt(t, y, h, size, bold)
		local l = Instance.new("TextLabel")
		l.Size = UDim2.new(1, -24, 0, h)
		l.Position = UDim2.new(0, 12, 0, y)
		l.BackgroundTransparency = 1
		l.TextColor3 = Color3.fromRGB(235, 235, 235)
		l.TextSize = size or 14
		l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
		l.Text = t
		l.Parent = box
		return l
	end

	txt("INDO AUTOFISH", 10, 24, 16, true)
	txt("Enter your key to continue", 36, 20, 13, false)
	local input = Instance.new("TextBox")
	input.Name = "KeyInput"
	input.Size = UDim2.new(1, -24, 0, 36)
	input.Position = UDim2.new(0, 12, 0, 60)
	input.BackgroundColor3 = Color3.fromRGB(45, 50, 62)
	input.TextColor3 = Color3.fromRGB(255, 255, 255)
	input.PlaceholderText = "xxxx-xxxx-xxxx"
	input.PlaceholderColor3 = Color3.fromRGB(140, 140, 150)
	input.TextSize = 15
	input.Font = Enum.Font.Gotham
	input.Text = ""
	input.ClearTextOnFocus = false
	input.Parent = box
	Instance.new("UICorner").Parent = input
	local go = Instance.new("TextButton")
	go.Name = "KeyGo"
	go.Size = UDim2.new(1, -24, 0, 36)
	go.Position = UDim2.new(0, 12, 0, 102)
	go.BackgroundColor3 = Color3.fromRGB(32, 120, 60)
	go.TextColor3 = Color3.fromRGB(255, 255, 255)
	go.TextSize = 15
	go.Font = Enum.Font.GothamBold
	go.Text = "Verify"
	go.Parent = box
	Instance.new("UICorner").Parent = go
	local getkey = Instance.new("TextButton")
	getkey.Name = "KeyGet"
	getkey.Size = UDim2.new(1, -24, 0, 32)
	getkey.Position = UDim2.new(0, 12, 0, 144)
	getkey.BackgroundColor3 = Color3.fromRGB(45, 50, 62)
	getkey.TextColor3 = Color3.fromRGB(255, 255, 255)
	getkey.TextSize = 14
	getkey.Font = Enum.Font.Gotham
	getkey.Text = "Get Key"
	getkey.Parent = box
	Instance.new("UICorner").Parent = getkey
	local status = txt("", 182, 22, 12, false)
	status.TextColor3 = Color3.fromRGB(255, 120, 120)
	getkey.Activated:Connect(function()
		local ok = false
		pcall(function()
			setclipboard("https://link-target.net/9258860/yPdMbtec04RT")
			ok = true
		end)
		status.TextColor3 = ok and Color3.fromRGB(120, 255, 120) or Color3.fromRGB(255, 120, 120)
		status.Text = ok and "Link copied, paste it in your browser" or "Copy failed: link-target.net/9258860/yPdMbtec04RT"
	end)

	local function tryUnlock()
		local v = tostring(input.Text or ""):gsub("%s+", ""):lower()
		local ok, which = validKey(v)
		if ok then
			CFG.Unlocked = true
			local main = pg:FindFirstChild("IndoAutoFishUI")
			if main then main.Enabled = true end
			gui:Destroy()
			print("[AutoFish] unlocked (" .. tostring(which) .. ")")
		else
			status.Text = "Wrong or expired key"
		end
	end
	go.Activated:Connect(tryUnlock)
	input.FocusLost:Connect(function(enter)
		if enter then tryUnlock() end
	end)
end)
