
local Players = game:GetService("Players")
local RS = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace and Workspace.CurrentCamera

-- Config
local ENABLE_INSTANT = false         -- false keeps projectile physics with gravity compensation
local ENABLE_WALLBANG = true         -- true shifts origin slightly into target to bypass walls
local MAX_FOV = 200                  -- pixels; nil to disable FOV limit
local TARGET_PART_NAME = "Head"      -- aim point
local TEAM_CHECK = true              -- skip same-team targets if the game uses Teams
local REQUIRE_ONSCREEN = true        -- only select targets that are actually on-screen

-- Try to require BulletFactory safely
local ok, Bullet = pcall(function()
    return require(ReplicatedStorage:WaitForChild("Components"):WaitForChild("BulletFactory"))
end)
if not ok or type(Bullet) ~= "table" then
    warn("[SilentAim] BulletFactory not found; aborting.")
    return
end

-- Utility: get mouse screen position
local function getMousePos()
    local pos = UIS:GetMouseLocation()
    -- MouseLocation Y includes top bar offset; Camera:ViewportSize handles it fine for our math.
    return Vector2.new(pos.X, pos.Y)
end

-- Utility: simple team check (best-effort; adapt to game’s team system if different)
local function isEnemy(plr: Player)
    if not TEAM_CHECK then return true end
    if not LocalPlayer or not plr then return true end
    if LocalPlayer.Team == nil or plr.Team == nil then return true end
    return plr.Team ~= LocalPlayer.Team
end

-- Returns closest enemy character to mouse (by screen distance), within FOV if set
local function getClosestToMouse()
    if not Camera then return end
    local mouse = getMousePos()
    local bestPlayer, bestChar
    local bestDist = math.huge

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and isEnemy(plr) then
            local char = plr.Character
            if char and char.Parent and char:FindFirstChild("HumanoidRootPart") then
                local root = char.HumanoidRootPart
                local screenPos, onScreen = Camera:WorldToScreenPoint(root.Position)
                if (not REQUIRE_ONSCREEN) or onScreen then
                    local dist = (Vector2.new(screenPos.X, screenPos.Y) - mouse).Magnitude
                    if (MAX_FOV == nil) or (dist <= MAX_FOV) then
                        if dist < bestDist then
                            bestDist = dist
                            bestPlayer = plr
                            bestChar = char
                        end
                    end
                end
            end
        end
    end

    return bestPlayer, bestChar
end

-- Gravity-compensated aim direction
-- Given origin O, target T, muzzle speed v, gravity g, compute direction vector d to hit T.
-- Solves for time t from vertical motion: T.y = O.y + v*d.y*t - 0.5*g*t^2, with |d| = 1.
-- We iterate on t using horizontal distance and update d each step (robust for gameplay).
local function solveBallisticDirection(origin: Vector3, target: Vector3, muzzleSpeed: number, gravity: number): Vector3?
    local dirXZ = Vector3.new(target.X - origin.X, 0, target.Z - origin.Z)
    local horizontalDist = dirXZ.Magnitude
    if horizontalDist < 1e-3 then
        -- Target above/below; just aim up/down with compensation
        local dy = target.Y - origin.Y
        local t = math.abs(dy) / math.max(muzzleSpeed, 1e-3)
        local vy = (dy + 0.5 * gravity * t * t) / math.max(t, 1e-3)
        local v = Vector3.new(0, vy, 0)
        return v.Magnitude > 1e-3 and v.Unit or nil
    end

    -- Initial time guess: flat shot (no drop), then refine
    local t = horizontalDist / math.max(muzzleSpeed, 1e-3)

    for _ = 1, 6 do
        -- Desired vertical component to land at target in time t
        local dy = target.Y - origin.Y
        local vy = (dy + 0.5 * gravity * t * t) / math.max(t, 1e-3)

        -- Horizontal speed needed to cover horizontalDist in time t
        local vxz = horizontalDist / math.max(t, 1e-3)

        -- Recompose unit direction from vxz along XZ to vy on Y
        local flatDir = dirXZ.Unit * vxz
        local vel = Vector3.new(flatDir.X, vy, flatDir.Z)
        local speed = vel.Magnitude
        if speed < 1e-3 then return nil end

        -- Enforce muzzle speed: adjust time so |vel| == muzzleSpeed
        -- speed ≈ distance_per_timestep / t -> refine t using ratio
        t = horizontalDist / math.max((muzzleSpeed * (flatDir.Magnitude / speed)), 1e-3)

        -- If close enough, stop early
        if math.abs(speed - muzzleSpeed) < 1 then
            return vel.Unit
        end
    end

    -- Final direction using last estimate
    local dy = target.Y - origin.Y
    local vy = (dy + 0.5 * gravity * t * t) / math.max(t, 1e-3)
    local vxz = horizontalDist / math.max(t, 1e-3)
    local flatDir = dirXZ.Unit * vxz
    local vel = Vector3.new(flatDir.X, vy, flatDir.Z)
    if vel.Magnitude < 1e-3 then return nil end
    return vel.Unit
end

-- Try to discover muzzle speed from BulletFactory if exposed; otherwise set a sane default
local function getMuzzleSpeed()
    -- If BulletFactory exposes something like Bullet.MuzzleSpeed, prefer it
    if type(Bullet) == "table" then
        for k, v in pairs(Bullet) do
            if type(v) == "number" and k:lower():find("speed") then
                return v
            end
        end
    end
    return 600 -- default studs/sec; tune to the game’s typical values
end

local muzzleSpeed = getMuzzleSpeed()
local gravity = Workspace.Gravity

-- Safe hook
local originalFire
if typeof(Bullet.Fire) == "function" and hookfunction then
    originalFire = hookfunction(Bullet.Fire, function(BulletId, Origin, BulletPos, ...)
        -- Guard camera/inputs
        if not Camera then
            return originalFire(BulletId, Origin, BulletPos, ...)
        end

        local player, character = getClosestToMouse()
        if player and character then
            local aimPart = character:FindFirstChild(TARGET_PART_NAME) or character:FindFirstChild("HumanoidRootPart")
            if aimPart then
                if ENABLE_INSTANT then
                    -- Original behavior: instant, straight-line wallbang
                    local newOrigin = ENABLE_WALLBANG and (aimPart.CFrame * CFrame.new(0, 0, 1)).Position or Origin
                    local newDir = (aimPart.Position - newOrigin).Unit
                    -- Very long forward vector to simulate “instant”
                    BulletPos = newDir * 10000
                    Origin = newOrigin
                else
                    -- Physics-preserving: compute compensated direction under gravity
                    local newOrigin = ENABLE_WALLBANG and (aimPart.CFrame * CFrame.new(0, 0, 0.2)).Position or Origin
                    local dir = solveBallisticDirection(newOrigin, aimPart.Position, muzzleSpeed, gravity)
                    if dir then
                        -- Let BulletFactory use its own stepper; we only supply origin + first step direction cast
                        -- BulletPos is expected as a direction * distance (based on original code pattern).
                        BulletPos = dir * (aimPart.Position - newOrigin).Magnitude
                        Origin = newOrigin
                    end
                end
            end
        end

        return originalFire(BulletId, Origin, BulletPos, ...)
    end)
else
    warn("[SilentAim] Could not hook Bullet.Fire (hookfunction missing or target not function).")
end

