--[[
	ModuleUI  -  tiny 3D UI utility (Part + SurfaceGui)
	-----------------------------------------------------
	WHERE:  ModuleScript, client only (e.g. ReplicatedStorage.ModuleUI).
	        Require it from a LocalScript.

	QUICK START
		local ModuleUI = require(game.ReplicatedStorage.ModuleUI)

		local ui = ModuleUI.new({
			Size = Vector3.new(3, 4.5, 0.05), -- studs; canvas = Size * PixelsPerStud
			Tilt = Vector2.new(0.02, 0.04),   -- optional mouse tilt (radians), nil = off
		})

		-- put your own UI inside ui.Canvas
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.fromScale(0.5, 0.1)
		btn.Text = "Hello"
		btn.Parent = ui.Canvas

		ui:SetCFrame(CFrame.new(0, 10, 0))    -- you place it yourself...
		-- ui:FollowCamera()                  -- ...or let it hug the camera
		ui:Show()

	API
		ModuleUI.new(config) -> ui
		  config (all optional):
		    Name, Size, PixelsPerStud, Face, AlwaysOnTop, Parent,
		    BackgroundColor3, BackgroundTransparency (default 1),
		    Tilt (Vector2), TiltSpeed, TrackMouse (default true),
		    DisableControls (stop the character walking while shown), Visible

		Fields:  ui.Part, ui.Gui (SurfaceGui), ui.Canvas (Frame you parent UI to)

		ui:SetCFrame(cf) / ui:GetCFrame()
		ui:FollowCamera(offset?)  offset = CFrame or function(cam, ui) -> CFrame
		ui:StopFollowing()
		ui:SetTilt(Vector2?)      nil turns tilt off
		ui:Show() / ui:Hide() / ui:Toggle() / ui:IsVisible()
		ui:GetMouse() -> Vector2? mouse position on the canvas in pixels (nil if not over it)
		ui:IsMouseOver() -> boolean
		ui:BindInput(name, callback(state, input), ...keycodes)  only active while shown
		ui:UnbindInput(name)
		ui:Destroy()

		Events:  ui.Shown, ui.Hidden, ui.MouseEntered, ui.MouseLeft,
		         ui.MouseMoved(pos), ui.Clicked(pos)

		Static:  ModuleUI.GetInputMode() -> "kbm" | "touch" | "gamepad"
		         ModuleUI.InputModeChanged(mode)
		         ModuleUI.Hover(guiObject, onEnter, onLeave) -> disconnect fn
		         ModuleUI.GetFitDistance(height, fill, cam?)

	NOTES
	  * Normal GuiObject events (MouseEnter, Activated, ...) already work on the
	    canvas while the panel is shown. GetMouse / Clicked are for custom stuff.
	  * Always move the panel with ui:SetCFrame (or FollowCamera) when Tilt or
	    FollowCamera is on, otherwise the internal update will overwrite Part.CFrame.
	  * GetMouse / MouseMoved / Clicked support the Front, Back, Left and Right faces.
	  * If your game locks the mouse (first person / shift-lock), unlock it yourself
	    while the panel is open.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")

assert(RunService:IsClient(), "ModuleUI can only be used on the client")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local ModuleUI = {}
ModuleUI.__index = ModuleUI

local nextId = 0

------------------------------------------------------------------
-- INPUT MODE (static)
------------------------------------------------------------------
function ModuleUI.GetInputMode()
	local t = UserInputService:GetLastInputType()
	if t == Enum.UserInputType.Touch then
		return "touch"
	end
	if t.Name:find("Gamepad") then
		return "gamepad"
	end
	return "kbm"
end

local modeEvent = Instance.new("BindableEvent")
ModuleUI.InputModeChanged = modeEvent.Event
local lastMode = ModuleUI.GetInputMode()
UserInputService.LastInputTypeChanged:Connect(function()
	local m = ModuleUI.GetInputMode()
	if m ~= lastMode then
		lastMode = m
		modeEvent:Fire(m)
	end
end)

------------------------------------------------------------------
-- STATIC HELPERS
------------------------------------------------------------------

-- Distance in front of the camera at which a panel of `height` studs fills
-- `fill` (0-1) of the screen height. Works on any screen size.
function ModuleUI.GetFitDistance(height, fill, cam)
	cam = cam or workspace.CurrentCamera
	local halfFov = math.tan(math.rad(cam.FieldOfView) / 2)
	return (height / (fill or 0.78)) / (2 * halfFov)
end

-- Hover that only fires for mouse users (so touch taps don't leave things "hovered").
function ModuleUI.Hover(guiObject, onEnter, onLeave)
	local hovered = false
	local c1 = guiObject.MouseEnter:Connect(function()
		if ModuleUI.GetInputMode() == "kbm" then
			hovered = true
			if onEnter then
				onEnter()
			end
		end
	end)
	local c2 = guiObject.MouseLeave:Connect(function()
		if hovered then
			hovered = false
			if onLeave then
				onLeave()
			end
		end
	end)
	return function()
		c1:Disconnect()
		c2:Disconnect()
	end
end

------------------------------------------------------------------
-- CHARACTER CONTROLS LOCK (shared, so several panels don't fight)
------------------------------------------------------------------
local controls = nil
local lockCount = 0

task.spawn(function()
	local ok, result = pcall(function()
		local module = player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 10)
		return require(module):GetControls()
	end)
	if ok then
		controls = result
		if lockCount > 0 then
			controls:Disable()
		end
	end
end)

local function setControlsLocked(self, on)
	if self._locked == on then
		return
	end
	self._locked = on
	lockCount += on and 1 or -1
	if controls then
		if lockCount > 0 then
			controls:Disable()
		else
			controls:Enable()
		end
	end
end

------------------------------------------------------------------
-- FACE MAPPING  (hit point on the part -> 0..1 UV on the SurfaceGui)
------------------------------------------------------------------
local function faceUV(face, lp, size)
	if face == Enum.NormalId.Back then
		return lp.X / size.X + 0.5, 0.5 - lp.Y / size.Y
	elseif face == Enum.NormalId.Front then
		return 0.5 - lp.X / size.X, 0.5 - lp.Y / size.Y
	elseif face == Enum.NormalId.Right then
		return 0.5 - lp.Z / size.Z, 0.5 - lp.Y / size.Y
	elseif face == Enum.NormalId.Left then
		return lp.Z / size.Z + 0.5, 0.5 - lp.Y / size.Y
	end
	return nil, nil -- Top / Bottom not supported
end

------------------------------------------------------------------
-- EVENTS
------------------------------------------------------------------
local EVENT_NAMES = { "Shown", "Hidden", "MouseEntered", "MouseLeft", "MouseMoved", "Clicked" }

local function fire(self, name, ...)
	local be = self._events[name]
	if be then
		be:Fire(...)
	end
end

------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------
function ModuleUI.new(config)
	config = config or {}
	nextId += 1

	local self = setmetatable({}, ModuleUI)
	self._id = nextId
	self._visible = false
	self._locked = false
	self._base = CFrame.identity
	self._tiltCF = CFrame.identity
	self._tilt = Vector2.zero
	self._tiltMax = config.Tilt
	self._tiltSpeed = config.TiltSpeed or 8
	self._follow = nil
	self._trackMouse = config.TrackMouse ~= false
	self._disableControls = config.DisableControls == true
	self._mouseOver = false
	self._lastMouse = nil
	self._inputs = {}
	self._conns = {}
	self._events = {}
	self._stepName = "ModuleUI_" .. self._id

	self.Face = config.Face or Enum.NormalId.Back -- the face that points at the camera

	for _, name in ipairs(EVENT_NAMES) do
		local be = Instance.new("BindableEvent")
		self._events[name] = be
		self[name] = be.Event
	end

	-- the 3D panel
	self.Part = Instance.new("Part")
	self.Part.Name = config.Name or "ModuleUIPanel"
	self.Part.Size = config.Size or Vector3.new(3, 4.5, 0.05)
	self.Part.Anchored = true
	self.Part.CanCollide = false
	self.Part.CanTouch = false
	self.Part.CanQuery = false -- turned on while shown so it can receive mouse rays
	self.Part.CastShadow = false
	self.Part.Transparency = 1
	self.Part.Parent = config.Parent or workspace

	-- the surface the UI draws on
	self.Gui = Instance.new("SurfaceGui")
	self.Gui.Name = (config.Name or "ModuleUI") .. "Surface"
	self.Gui.Adornee = self.Part
	self.Gui.Face = self.Face
	self.Gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	self.Gui.PixelsPerStud = config.PixelsPerStud or 200
	self.Gui.AlwaysOnTop = config.AlwaysOnTop ~= false -- never clips into walls
	self.Gui.LightInfluence = 0
	self.Gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	self.Gui.ResetOnSpawn = false
	self.Gui.Enabled = false
	self.Gui.Parent = playerGui

	-- your UI goes in here
	self.Canvas = Instance.new("Frame")
	self.Canvas.Name = "Canvas"
	self.Canvas.Size = UDim2.fromScale(1, 1)
	self.Canvas.BorderSizePixel = 0
	self.Canvas.BackgroundColor3 = config.BackgroundColor3 or Color3.new(0, 0, 0)
	self.Canvas.BackgroundTransparency = config.BackgroundTransparency or 1
	self.Canvas.Parent = self.Gui

	-- ray params: only ever hit our own panel
	self._rayParams = RaycastParams.new()
	self._rayParams.FilterType = Enum.RaycastFilterType.Include
	self._rayParams.FilterDescendantsInstances = { self.Part }

	-- custom click detection (works for mouse + touch)
	table.insert(self._conns, UserInputService.InputBegan:Connect(function(input)
		if not self._visible then
			return
		end
		local t = input.UserInputType
		local viewportPos
		if t == Enum.UserInputType.MouseButton1 then
			viewportPos = UserInputService:GetMouseLocation()
		elseif t == Enum.UserInputType.Touch then
			-- touch positions are in GUI space; ViewportPointToRay wants viewport space
			viewportPos = Vector2.new(input.Position.X, input.Position.Y) + GuiService:GetGuiInset()
		else
			return
		end
		local pos = self:_toCanvas(viewportPos)
		if pos then
			fire(self, "Clicked", pos)
		end
	end))

	if config.Visible then
		self:Show()
	end

	return self
end

------------------------------------------------------------------
-- CFRAME
------------------------------------------------------------------
function ModuleUI:SetCFrame(cf)
	self._base = cf
	self.Part.CFrame = cf * self._tiltCF
end

function ModuleUI:GetCFrame()
	return self._base
end

-- Keeps the panel glued in front of the camera every frame.
-- offset: CFrame (relative to the camera) or function(cam, ui) -> CFrame.
-- Default: centered, at the distance where it fills ~78% of the screen height.
function ModuleUI:FollowCamera(offset)
	self._follow = offset or function(cam)
		return CFrame.new(0, 0, -ModuleUI.GetFitDistance(self.Part.Size.Y, 0.78, cam))
	end
end

function ModuleUI:StopFollowing()
	self._follow = nil
end

function ModuleUI:SetTilt(maxTilt)
	self._tiltMax = maxTilt
	if not maxTilt then
		self._tilt = Vector2.zero
		self._tiltCF = CFrame.identity
		self.Part.CFrame = self._base
	end
end

------------------------------------------------------------------
-- MOUSE
------------------------------------------------------------------

-- viewport position -> pixel position on the canvas (nil if it misses the panel)
function ModuleUI:_toCanvas(viewportPos)
	if not self._visible then
		return nil
	end
	local cam = workspace.CurrentCamera
	if not cam then
		return nil
	end
	local ray = cam:ViewportPointToRay(viewportPos.X, viewportPos.Y)
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 1000, self._rayParams)
	if not hit then
		return nil
	end
	local lp = self.Part.CFrame:PointToObjectSpace(hit.Position)
	local u, v = faceUV(self.Face, lp, self.Part.Size)
	if not u or u < 0 or u > 1 or v < 0 or v > 1 then
		return nil
	end
	local abs = self.Gui.AbsoluteSize
	return Vector2.new(u * abs.X, v * abs.Y)
end

-- Mouse position on the canvas in pixels, or nil if the mouse isn't over the panel.
function ModuleUI:GetMouse()
	return self:_toCanvas(UserInputService:GetMouseLocation())
end

function ModuleUI:IsMouseOver()
	return self._mouseOver
end

------------------------------------------------------------------
-- CUSTOM KEY / GAMEPAD INPUT (only bound while the panel is shown)
------------------------------------------------------------------
function ModuleUI:_bindOne(name)
	local entry = self._inputs[name]
	if not entry then
		return
	end
	ContextActionService:BindActionAtPriority(
		"ModuleUI" .. self._id .. "_" .. name,
		function(_, state, input)
			local result = entry.fn(state, input)
			return result or Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.High.Value,
		table.unpack(entry.keys)
	)
end

-- callback(state, input): state is Enum.UserInputState. Return
-- Enum.ContextActionResult.Pass to let the input through; sinks by default.
function ModuleUI:BindInput(name, callback, ...)
	if self._inputs[name] and self._visible then
		ContextActionService:UnbindAction("ModuleUI" .. self._id .. "_" .. name)
	end
	self._inputs[name] = { fn = callback, keys = { ... } }
	if self._visible then
		self:_bindOne(name)
	end
end

function ModuleUI:UnbindInput(name)
	if self._inputs[name] then
		ContextActionService:UnbindAction("ModuleUI" .. self._id .. "_" .. name)
		self._inputs[name] = nil
	end
end

------------------------------------------------------------------
-- PER-FRAME UPDATE (bound only while shown, right after the camera)
------------------------------------------------------------------
function ModuleUI:_step(dt)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end

	-- follow camera
	if self._follow then
		local off = self._follow
		if type(off) == "function" then
			off = off(cam, self)
		end
		self._base = cam.CFrame * off
	end

	-- mouse tilt (kbm only; eases back to flat otherwise)
	if self._tiltMax then
		local target = Vector2.zero
		if ModuleUI.GetInputMode() == "kbm" then
			local m = UserInputService:GetMouseLocation()
			local vp = cam.ViewportSize
			target = Vector2.new(
				math.clamp((m.X / vp.X - 0.5) * 2, -1, 1),
				math.clamp((m.Y / vp.Y - 0.5) * 2, -1, 1)
			)
		end
		self._tilt = self._tilt:Lerp(target, 1 - math.exp(-self._tiltSpeed * dt))
		-- if the tilt feels inverted, flip the signs of these two values
		self._tiltCF = CFrame.Angles(self._tilt.Y * self._tiltMax.X, self._tilt.X * self._tiltMax.Y, 0)
	end

	if self._follow or self._tiltMax then
		self.Part.CFrame = self._base * self._tiltCF
	end

	-- mouse enter / leave / move on the panel
	if self._trackMouse then
		local pos = ModuleUI.GetInputMode() == "kbm" and self:GetMouse() or nil
		if pos then
			if not self._mouseOver then
				self._mouseOver = true
				fire(self, "MouseEntered")
			end
			if pos ~= self._lastMouse then
				self._lastMouse = pos
				fire(self, "MouseMoved", pos)
			end
		elseif self._mouseOver then
			self._mouseOver = false
			self._lastMouse = nil
			fire(self, "MouseLeft")
		end
	end
end

------------------------------------------------------------------
-- SHOW / HIDE
------------------------------------------------------------------
function ModuleUI:Show()
	if self._visible then
		return
	end
	self._visible = true
	self.Part.CanQuery = true
	self.Gui.Enabled = true

	RunService:BindToRenderStep(self._stepName, Enum.RenderPriority.Camera.Value + 1, function(dt)
		self:_step(dt)
	end)
	for name in pairs(self._inputs) do
		self:_bindOne(name)
	end
	if self._disableControls then
		setControlsLocked(self, true)
	end
	fire(self, "Shown")
end

function ModuleUI:Hide()
	if not self._visible then
		return
	end
	self._visible = false

	RunService:UnbindFromRenderStep(self._stepName)
	for name in pairs(self._inputs) do
		ContextActionService:UnbindAction("ModuleUI" .. self._id .. "_" .. name)
	end
	setControlsLocked(self, false)

	if self._mouseOver then
		self._mouseOver = false
		self._lastMouse = nil
		fire(self, "MouseLeft")
	end

	self.Part.CanQuery = false -- so the hidden panel never blocks other mouse rays
	self.Gui.Enabled = false
	fire(self, "Hidden")
end

function ModuleUI:Toggle()
	if self._visible then
		self:Hide()
	else
		self:Show()
	end
end

function ModuleUI:IsVisible()
	return self._visible
end

------------------------------------------------------------------
-- CLEANUP
------------------------------------------------------------------
function ModuleUI:Destroy()
	self:Hide()
	for _, c in ipairs(self._conns) do
		c:Disconnect()
	end
	for name in pairs(self._inputs) do
		ContextActionService:UnbindAction("ModuleUI" .. self._id .. "_" .. name)
	end
	for _, be in pairs(self._events) do
		be:Destroy()
	end
	self.Gui:Destroy()
	self.Part:Destroy()
	table.clear(self._inputs)
end

return ModuleUI
