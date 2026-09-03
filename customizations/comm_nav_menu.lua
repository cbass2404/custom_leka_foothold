local navMenuEnabled = NavMenuEnabled ~= false
local navMenuResultCount = NavMenuResultCount or 5
local navMenuDisplayTime = NavMenuDisplayTime or 30
-- A red zone this close to the front line is reported FRONT rather than REAR.
local navFrontlineThresholdNm = NavFrontlineThresholdNm or 15

-- ============================================================================
-- Comm Navigation Menu
--
-- A GCI style navigation desk on the F10 menu, aimed at the older airframes
-- that fly this server on dead reckoning. Three calls, each answered only to
-- the group that asked:
--
--   Get Magnetic Variation    variation at the aircraft's own position
--   Get Friendly Landing Zones  nearest fields this airframe can actually use
--   Get Nearest Objectives    nearest red zones, with what is waiting there
--
-- Menus are per group and DCS gives the callback no way to tell which seat
-- pressed the key, so a group is the finest scope available. On this server
-- that is also a player: the slots are dynamic spawns, one group each.
--
-- Deliberately built on stock DCS API rather than Foothold's internals wherever
-- there was a choice. Lekas-Foothold is vendored and re-pulled after every
-- upstream release, so a private helper borrowed today is a silent breakage
-- three releases from now. The unavoidable couplings are bc:getZones() and the
-- documented public fields on a ZoneCommander, plus an optional read of the
-- Frontline table. Everything else here is DCS or self contained.
-- ============================================================================

local NAV_LOG_PREFIX = "[Nav Menu]: "

local M_TO_NM = 1 / 1852
local M_TO_KM = 1 / 1000
local M_TO_SM = 1 / 1609.344
-- One Swedish mil is 10 km.
local M_TO_SEMIL = 1 / 10000
local HPA_TO_INHG = 0.0295299830714
local HPA_TO_MMHG = 0.7500615613030

-- The Viggen's distance readout is in km until the number would get unwieldy,
-- then switches to Swedish mil. Reported by the pilots who fly it here.
local SEMIL_THRESHOLD_M = 40000

-- Cells are separated by this and nothing else. There is no column padding:
-- DCS renders these messages in a proportional font, so padding to a character
-- count never lined the pipes up anyway, and it cost a row's whole width in
-- whitespace to fail at it. A fixed separator reads the same at any name
-- length, which is what matters when a long airfield name turns up.
local CELL_SEPARATOR = "  |  "

local function Log(logger, format, ...)
    logger(NAV_LOG_PREFIX .. string.format(format, ...))
end

-- ============================================================================
-- Magnetic variation
--
-- DCS ships the same WMM module its Mission Editor uses, which is the only
-- source here that is accurate to a position and a mission date. It arrives
-- through require, and require is nulled by the stock MissionScripting.lua on
-- its own line, separately from the io and lfs that Foothold's persistence
-- already needs. So a server can be desanitized enough for Foothold and still
-- have no magnetic model.
--
-- There is deliberately no fallback. MOOSE offers a flat per-map constant and
-- it is worse than nothing for this feature: variation swings several degrees
-- across a single map, so a constant quietly hands a dead reckoning pilot a
-- number that is wrong in exactly the places it matters. When the model is
-- missing the reports say so and fall back to true bearings, clearly labelled.
-- A true bearing a pilot knows is true can be flown. A magnetic bearing that is
-- silently wrong cannot.
-- ============================================================================

local magvarModule = nil

local function InitMagvar()
    if not require then
        Log(env.warning, "require is sanitized, no magnetic model. Bearings will be reported TRUE.")
        return
    end

    local ok, module = pcall(require, "magvar")

    if not ok or type(module) ~= "table" or not module.get_mag_decl then
        Log(env.warning, "magvar module unavailable, bearings will be reported TRUE.")
        return
    end

    -- The model drifts with date, and this mission runs Cold War through modern,
    -- so seed it from the mission date rather than letting it assume an epoch.
    local date = env.mission and env.mission.date
    local year = date and date.Year or 2024
    local month = date and date.Month or 1

    local initOk = pcall(module.init, month, year)

    if not initOk then
        Log(env.warning, "magvar.init failed for %04d-%02d, bearings will be reported TRUE.", year, month)
        return
    end

    magvarModule = module
    Log(env.info, "magnetic model armed for mission date %04d-%02d.", year, month)
end

-- Degrees, east positive, or nil when there is no model. nil is a real answer
-- here and every caller has to handle it.
local function GetMagVar(vec3)
    if not magvarModule then
        return nil
    end

    local ok, lat, lon = pcall(coord.LOtoLL, vec3)

    if not ok or not lat then
        return nil
    end

    local declOk, decl = pcall(magvarModule.get_mag_decl, lat, lon)

    if not declOk or not decl then
        return nil
    end

    -- The module answers in radians.
    return math.deg(decl)
end

-- ============================================================================
-- Airframe profiles
--
-- What the pilot's own instruments read, so the report does not make them
-- convert. Distance follows the airspeed indicator: knots pair with nautical
-- miles, mph with statute miles, km/h with kilometres. Pressure is its own
-- axis: US airframes read inHg, western European and Swedish read hPa, Soviet
-- read mmHg.
--
-- Datum picks which pressure gets sent, and only that one is sent: this is a
-- readout a pilot takes in at a glance while flying, not a weather brief. It
-- carries its own QNH or QFE label so the number cannot be mistaken for the
-- other when it is read out or written down. NATO practice is QNH, Soviet
-- practice and the warbirds QFE.
--
-- Helicopters are the exception to the distance rule: they always read
-- kilometres, whatever their nation flies fixed wing in. Rotary crews plan,
-- brief and call ranges in km, so NM in a Huey would be a conversion the pilot
-- has to undo. That comes from the rotary entries below and nothing else.
--
-- Keyed on DCS type names, which match the ones in Foothold's CAREER_AIRCRAFT
-- table. Init audits this against that table and logs anything missing, so a
-- module ED adds shows up in dcs.log rather than silently reading as a Viper.
-- Third party mods are the gap in that audit: Foothold does not list them, so
-- nothing will tell you they are missing. Add them here by hand.
--
-- An unmatched type name gets DEFAULT_PROFILE unchanged. That is the whole
-- fallback, deliberately: no guessing off the unit's category, no half matched
-- profile assembled at runtime. A new module reads as a Viper until it is added
-- here, which is a known quantity rather than a plausible looking invention.
-- ============================================================================

local PROFILE_US_JET = {
    dist = "NM",
    press = "inHg",
    datum = "QNH"
}
local PROFILE_EURO_JET = {
    dist = "NM",
    press = "hPa",
    datum = "QNH"
}
local PROFILE_SOVIET = {
    dist = "km",
    press = "mmHg",
    datum = "QFE"
}
local PROFILE_US_PROP = {
    dist = "SM",
    press = "inHg",
    datum = "QFE"
}
local PROFILE_UK_PROP = {
    dist = "SM",
    press = "hPa",
    datum = "QFE"
}
local PROFILE_DE_PROP = {
    dist = "km",
    press = "hPa",
    datum = "QFE"
}
local PROFILE_VIGGEN = {
    dist = "SEmil",
    press = "hPa",
    datum = "QFE"
}

-- Rotary. Same pressure and datum as the nation's fast jets, distance always
-- in km. Soviet rotary is a separate table from PROFILE_SOVIET despite holding
-- the same values today, so a later edit to the fixed wing Soviet profile
-- cannot quietly move the Hind off kilometres.
local PROFILE_US_HELO = {
    dist = "km",
    press = "inHg",
    datum = "QNH"
}
local PROFILE_EURO_HELO = {
    dist = "km",
    press = "hPa",
    datum = "QNH"
}
local PROFILE_SOVIET_HELO = {
    dist = "km",
    press = "mmHg",
    datum = "QFE"
}

local DEFAULT_PROFILE = PROFILE_US_JET

local airframe_profiles = {
    -- US and NATO fast jets
    ["FA-18C_hornet"] = PROFILE_US_JET,
    ["FA-18E"] = PROFILE_US_JET,
    ["FA-18ET"] = PROFILE_US_JET,
    ["FA-18F"] = PROFILE_US_JET,
    ["FA-18FT"] = PROFILE_US_JET,
    ["EA-18G"] = PROFILE_US_JET,
    ["F-16C_50"] = PROFILE_US_JET,
    ["F-14A"] = PROFILE_US_JET,
    ["F-14A-95-GR"] = PROFILE_US_JET,
    ["F-14A-135-GR"] = PROFILE_US_JET,
    ["F-14A-135-GR-Early"] = PROFILE_US_JET,
    ["F-14B"] = PROFILE_US_JET,
    ["F-14BU"] = PROFILE_US_JET,
    ["F-15ESE"] = PROFILE_US_JET,
    ["F-15C"] = PROFILE_US_JET,
    ["A-10A"] = PROFILE_US_JET,
    ["A-10C"] = PROFILE_US_JET,
    ["A-10C_2"] = PROFILE_US_JET,
    ["AV8BNA"] = PROFILE_US_JET,
    ["F-4E-45MC"] = PROFILE_US_JET,
    ["F-5E-3"] = PROFILE_US_JET,
    ["F-5E-3_FC"] = PROFILE_US_JET,
    ["F-86F Sabre"] = PROFILE_US_JET,
    ["F-100D"] = PROFILE_US_JET,
    ["C-130J-30"] = PROFILE_US_JET,
    ["Hercules"] = PROFILE_US_JET,
    ["Bronco-OV-10A"] = PROFILE_US_JET,

    -- Third party mods this mission allows. Grouped by what the audit can see
    -- rather than by nation: none of these are in Foothold's CAREER_AIRCRAFT,
    -- so AuditProfileCoverage will never flag one as missing however wrong it
    -- reads. Keep this block in step with allowedPlanes by hand.
    ["A-4E-C"] = PROFILE_US_JET,
    -- Warsaw Pact instrumentation: metric, mmHg, QFE by practice.
    ["L-39C"] = PROFILE_SOVIET,
    ["SU22"] = PROFILE_SOVIET,
    -- Western trainers. Knots and feet on the dials, millibar subscale.
    ["C-101CC"] = PROFILE_EURO_JET,
    ["MB-339A"] = PROFILE_EURO_JET,
    ["MB-339APAN"] = PROFILE_EURO_JET,

    -- Western European jets. Knots and nautical miles, but millibars.
    ["M-2000C"] = PROFILE_EURO_JET,
    ["JF-17"] = PROFILE_EURO_JET,
    ["Mirage-F1AD"] = PROFILE_EURO_JET,
    ["Mirage-F1AZ"] = PROFILE_EURO_JET,
    ["Mirage-F1B"] = PROFILE_EURO_JET,
    ["Mirage-F1BD"] = PROFILE_EURO_JET,
    ["Mirage-F1BE"] = PROFILE_EURO_JET,
    ["Mirage-F1BQ"] = PROFILE_EURO_JET,
    ["Mirage-F1C"] = PROFILE_EURO_JET,
    ["Mirage-F1C-200"] = PROFILE_EURO_JET,
    ["Mirage-F1CE"] = PROFILE_EURO_JET,
    ["Mirage-F1CG"] = PROFILE_EURO_JET,
    ["Mirage-F1CH"] = PROFILE_EURO_JET,
    ["Mirage-F1CJ"] = PROFILE_EURO_JET,
    ["Mirage-F1CK"] = PROFILE_EURO_JET,
    ["Mirage-F1CR"] = PROFILE_EURO_JET,
    ["Mirage-F1CT"] = PROFILE_EURO_JET,
    ["Mirage-F1CZ"] = PROFILE_EURO_JET,
    ["Mirage-F1DDA"] = PROFILE_EURO_JET,
    ["Mirage-F1ED"] = PROFILE_EURO_JET,
    ["Mirage-F1EDA"] = PROFILE_EURO_JET,
    ["Mirage-F1EE"] = PROFILE_EURO_JET,
    ["Mirage-F1EH"] = PROFILE_EURO_JET,
    ["Mirage-F1EQ"] = PROFILE_EURO_JET,
    ["Mirage-F1M-CE"] = PROFILE_EURO_JET,
    ["Mirage-F1M-EE"] = PROFILE_EURO_JET,

    -- Swedish. Kilometres below 50, Swedish mil above.
    ["AJS37"] = PROFILE_VIGGEN,

    -- Soviet jets
    ["MiG-21Bis"] = PROFILE_SOVIET,
    ["MiG-19P"] = PROFILE_SOVIET,
    ["MiG-15bis"] = PROFILE_SOVIET,
    ["MiG-15bis_FC"] = PROFILE_SOVIET,
    ["MiG-29A"] = PROFILE_SOVIET,
    ["MiG-29G"] = PROFILE_SOVIET,
    ["MiG-29S"] = PROFILE_SOVIET,
    ["MiG-29 Fulcrum"] = PROFILE_SOVIET,
    ["Su-25"] = PROFILE_SOVIET,
    ["Su-25T"] = PROFILE_SOVIET,
    ["Su-27"] = PROFILE_SOVIET,
    ["Su-33"] = PROFILE_SOVIET,
    ["J-11A"] = PROFILE_SOVIET,

    -- Rotary. All km, whatever the nation's fixed wing reads.
    ["UH-1H"] = PROFILE_US_HELO,
    ["UH-60L"] = PROFILE_US_HELO,
    ["UH-60L_DAP"] = PROFILE_US_HELO,
    ["CH-47Fbl1"] = PROFILE_US_HELO,
    ["AH-64D_BLK_II"] = PROFILE_US_HELO,
    ["OH58D"] = PROFILE_US_HELO,
    ["OH-6A"] = PROFILE_US_HELO,
    ["SA342L"] = PROFILE_EURO_HELO,
    ["SA342M"] = PROFILE_EURO_HELO,
    ["SA342Minigun"] = PROFILE_EURO_HELO,
    ["SA342Mistral"] = PROFILE_EURO_HELO,
    ["Mi-8MT"] = PROFILE_SOVIET_HELO,
    ["Mi-8MTV2"] = PROFILE_SOVIET_HELO,
    ["Mi-24P"] = PROFILE_SOVIET_HELO,
    ["Mi-24V"] = PROFILE_SOVIET_HELO,
    ["Ka-50"] = PROFILE_SOVIET_HELO,
    ["Ka-50_3"] = PROFILE_SOVIET_HELO,

    -- Warbirds. All QFE, split by nation on unit and pressure.
    ["P-51D"] = PROFILE_US_PROP,
    ["P-51D-25-NA"] = PROFILE_US_PROP,
    ["P-51D-30-NA"] = PROFILE_US_PROP,
    ["TF-51D"] = PROFILE_US_PROP,
    ["P-47D-30"] = PROFILE_US_PROP,
    ["P-47D-30bl1"] = PROFILE_US_PROP,
    ["P-47D-40"] = PROFILE_US_PROP,
    ["F4U-1D"] = PROFILE_US_PROP,
    ["F4U-1D_CW"] = PROFILE_US_PROP,
    ["SpitfireLFMkIX"] = PROFILE_UK_PROP,
    ["SpitfireLFMkIXCW"] = PROFILE_UK_PROP,
    ["MosquitoFBMkVI"] = PROFILE_UK_PROP,
    ["Bf-109K-4"] = PROFILE_DE_PROP,
    ["FW-190A8"] = PROFILE_DE_PROP,
    ["FW-190D9"] = PROFILE_DE_PROP,
    ["I-16"] = PROFILE_SOVIET,
    ["La-7"] = PROFILE_SOVIET,
    ["Yak-52"] = PROFILE_SOVIET
}

local function IsHelicopter(unitObj)
    local desc = unitObj.getDesc and unitObj:getDesc()

    if desc and desc.category ~= nil and Unit and Unit.Category then
        return desc.category == Unit.Category.HELICOPTER
    end

    return false
end

-- One lookup, one fallback, no inference from the unit itself. A module that
-- releases before this table catches up reads exactly as a Viper does, which is
-- a known quantity a pilot can convert from, rather than a guess assembled from
-- its category that looks authoritative and may not be.
local function GetProfile(typeName)
    return airframe_profiles[typeName] or DEFAULT_PROFILE
end

-- Foothold already keeps the definitive list of type names it supports. Diff
-- against it once at load so a missing profile is a log line rather than a
-- pilot quietly reading inches of mercury in a Hind. A miss here gets the
-- distance unit, the pressure unit and the datum wrong all at once, and only
-- this audit would say so. It cannot see third party mods at all, since
-- Foothold's list does not carry them.
local function AuditProfileCoverage()
    local career = BattleCommander and BattleCommander.CAREER_AIRCRAFT

    if not career then
        return
    end

    local missing = {}

    for _, definition in pairs(career) do
        for _, typeName in ipairs(definition.typeNames or {}) do
            if not airframe_profiles[typeName] then
                missing[#missing + 1] = typeName
            end
        end
    end

    if #missing > 0 then
        table.sort(missing)
        Log(env.warning, "no unit profile for %d airframe(s), defaulting to NM/inHg/QNH: %s", #missing,
            table.concat(missing, ", "))
    end
end

-- ============================================================================
-- Formatting
-- ============================================================================

-- Upper case to match the rest of the report, and never nil: a zone that has
-- lost its name should read as a question mark rather than crash the row it
-- appears in. Names are printed at whatever length they are, since the cells
-- are not padded to a width any more.
local function FormatName(name)
    return tostring(name or "?"):upper()
end

local function FormatDistance(metres, profile)
    local unit = profile.dist

    if unit == "SEmil" then
        if metres >= SEMIL_THRESHOLD_M then
            return string.format("%.1f MIL", metres * M_TO_SEMIL)
        end

        return string.format("%.1f KM", metres * M_TO_KM)
    elseif unit == "km" then
        return string.format("%.1f KM", metres * M_TO_KM)
    elseif unit == "SM" then
        return string.format("%.1f SM", metres * M_TO_SM)
    end

    return string.format("%.1f NM", metres * M_TO_NM)
end

-- Magnetic where there is a model, true where there is not, and never silently
-- one wearing the other's suffix.
local function FormatBearing(trueBearing, magVar)
    if magVar then
        return string.format("%03d\194\176M", math.floor((trueBearing - magVar) % 360 + 0.5) % 360)
    end

    return string.format("%03d\194\176T", math.floor(trueBearing % 360 + 0.5) % 360)
end

local function FormatVariation(magVar)
    if not magVar then
        return "UNAVAILABLE"
    end

    return string.format("%+.1f\194\176 %s", magVar, magVar >= 0 and "EAST" or "WEST")
end

local function FormatDDM(lat, lon)
    local function component(value, positive, negative, degreeDigits)
        local hemisphere = value >= 0 and positive or negative
        value = math.abs(value)

        local degrees = math.floor(value)
        local minutes = (value - degrees) * 60

        return string.format("%s%0" .. degreeDigits .. "d\194\176%04.1f'", hemisphere, degrees, minutes)
    end

    return component(lat, "N", "S", 2) .. "  " .. component(lon, "E", "W", 3)
end

local function FormatMGRS(lat, lon)
    local ok, mgrs = pcall(coord.LLtoMGRS, lat, lon)

    if not ok or type(mgrs) ~= "table" or not mgrs.UTMZone then
        return nil
    end

    -- Four digit easting and northing, so 10 m precision. Enough to fly to and
    -- short enough to copy onto a kneeboard in the air.
    return string.format("%s %s %04d %04d", mgrs.UTMZone, mgrs.MGRSDigraph, math.floor((mgrs.Easting or 0) / 10),
        math.floor((mgrs.Northing or 0) / 10))
end

-- QFE is the pressure the field actually sits in, QNH the same reduced to sea
-- level. One value, the one this airframe's crew actually sets, sampled at the
-- height its datum implies. The label rides along with it so the number is not
-- ambiguous when it gets read out on the radio or copied to a kneeboard, but
-- there is only ever one number to take in.
--
-- Sampling the atmosphere at y=0 for QNH is what MOOSE's ATIS does, so the
-- model is known to extrapolate sensibly below terrain.
local function FormatPressure(vec3, profile)
    local datum = profile.datum
    local sampleHeight = datum == "QFE" and (vec3.y or 0) or 0

    local ok, _, pascals = pcall(atmosphere.getTemperatureAndPressure, {
        x = vec3.x,
        y = sampleHeight,
        z = vec3.z
    })

    if not ok or not pascals then
        return datum .. " --"
    end

    local hPa = pascals / 100

    if profile.press == "inHg" then
        return string.format("%s %.2f inHg", datum, hPa * HPA_TO_INHG)
    elseif profile.press == "mmHg" then
        return string.format("%s %.1f mmHg", datum, hPa * HPA_TO_MMHG)
    end

    return string.format("%s %.1f hPa", datum, hPa)
end

-- ============================================================================
-- Geometry and group lookup
-- ============================================================================

-- Squared metres, for ranking only. Ordering by the square is the same ordering
-- as by the distance, so nothing before the cut has to pay for a root or an
-- arctangent. This is what every candidate gets.
local function RangeSquared(from, to)
    local dx = to.x - from.x
    local dz = to.z - from.z

    return dx * dx + dz * dz
end

-- DCS lays x to the north and z to the east, so this is a compass bearing
-- straight out of atan2 with no axis swap needed.
--
-- Called only for the handful of entries that survive NearestFew and will
-- actually be printed. atan2 is a real libm call, and running one per zone to
-- then discard nine tenths of the answers is the kind of cost that does not
-- show up with one player on the server and does with twenty.
local function BearingRange(from, to)
    local dx = to.x - from.x
    local dz = to.z - from.z

    return math.deg(math.atan2(dz, dx)) % 360, math.sqrt(dx * dx + dz * dz)
end

-- Resolved at press time rather than captured when the menu was built: with
-- dynamic spawns the unit behind a group id is replaced on every re-slot, and a
-- stale reference would report a position the pilot left ten minutes ago.
local function GetRequestingUnit(groupId)
    for _, unitObj in pairs(coalition.getPlayers(coalition.side.BLUE) or {}) do
        if unitObj and unitObj:isExist() then
            local groupObj = unitObj:getGroup()

            if groupObj and groupObj:isExist() and groupObj:getID() == groupId then
                return unitObj
            end
        end
    end
end

-- ============================================================================
-- Zone reads
--
-- Only public ZoneCommander fields are touched here. Hidden zones are dropped
-- everywhere without exception: Foothold hides zones the coalition has not
-- discovered, and a navigation menu that lists one has leaked the campaign.
-- ============================================================================

local function ZoneIsVisible(zone)
    return zone and zone.active and not zone.suspended and not zone.isHidden
end

-- The landing surface, not the trigger zone's centre, and read live so a moving
-- object is not reported where it was at mission start.
local function GetZonePoint(zone)
    if zone.airbaseName then
        local ok, airbase = pcall(Airbase.getByName, zone.airbaseName)

        if ok and airbase and airbase:isExist() then
            local point = airbase:getPoint()

            if point then
                return point
            end
        end
    end

    local ok, triggerZone = pcall(trigger.misc.getZone, zone.zone)

    if ok and triggerZone and triggerZone.point then
        local point = triggerZone.point
        return {
            x = point.x,
            y = land.getHeight({
                x = point.x,
                y = point.z
            }) or 0,
            z = point.z
        }
    end
end

-- Every blue zone with red forces committed against it, built in one pass so
-- the airfield report does not walk the whole order of battle once per field.
--
-- Three signals, any one of which is enough. pendingCapture means red is on the
-- field running the capture clock. A red attack GroupCommander pointed at the
-- zone and out of the hangar means red is on the way, which is what a pilot
-- picking a divert actually needs to know. _zoneAttackFlashes is private and
-- only ever populated by mission editor triggers, so it is read defensively and
-- treated as a bonus rather than depended on.
local ACTIVE_GROUP_STATES = {
    preparing = true,
    takeoff = true,
    inair = true,
    landed = true,
    enroute = true,
    atdestination = true
}

local function BuildThreatenedZoneSet()
    local threatened = {}

    for _, zone in ipairs(bc:getZones() or {}) do
        local pending = zone.pendingCapture

        if pending and pending.side == coalition.side.RED then
            threatened[zone.zone] = true
        end

        for _, groupCommander in ipairs(zone.groups or {}) do
            if groupCommander.side == coalition.side.RED and groupCommander.mission == "attack" and
                groupCommander.targetzone and ACTIVE_GROUP_STATES[groupCommander.state] == true then
                threatened[groupCommander.targetzone] = true
            end
        end
    end

    for zoneName in pairs(bc._zoneAttackFlashes or {}) do
        threatened[zoneName] = true
    end

    return threatened
end

-- Read off the live units rather than the upgrade template names. Those names
-- are a setup file convention, not an API: Syria alone spells it both
-- 'Red Armour Group' and 'Red Armor Group', and Kola names its groups after
-- towns. Unit attributes are DCS's own and mean the same thing on every map.
--
-- Ordered most dangerous first and capped, because this is the last column on
-- an already wide row and a full order of battle would wrap it.
--
-- EWR's rank is close to academic on this mission: an EWR is always its own
-- objective, sited apart so it can cue several SAM zones at once, so it never
-- competes with launchers for one of the three slots. It ranks here rather than
-- first because the order is about what threatens the aircraft, and a radar
-- does not.
local DEFENCE_CATEGORIES = {{
    label = "SAM",
    attributes = {"LR SAM", "MR SAM"}
}, {
    label = "SHORAD",
    attributes = {"SR SAM", "MANPADS"}
}, {
    label = "AAA",
    attributes = {"AAA"}
}, {
    label = "EWR",
    attributes = {"EWR"}
}, {
    label = "ARMOR",
    attributes = {"Tanks", "IFV", "APC"}
}, {
    label = "ARTY",
    attributes = {"Artillery"}
}, {
    label = "TROOPS",
    attributes = {"Infantry"}
}}

local DEFENCE_LABEL_LIMIT = 3

local function DescribeDefences(zone)
    local found = {}

    for _, groupName in pairs(zone.built or {}) do
        local ok, groupObj = pcall(Group.getByName, groupName)

        if ok and groupObj and groupObj:isExist() then
            for _, unitObj in ipairs(groupObj:getUnits() or {}) do
                if unitObj and unitObj:isExist() and unitObj:getLife() > 0 then
                    for _, category in ipairs(DEFENCE_CATEGORIES) do
                        if not found[category.label] then
                            for _, attribute in ipairs(category.attributes) do
                                if unitObj:hasAttribute(attribute) then
                                    found[category.label] = true
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local labels = {}

    for _, category in ipairs(DEFENCE_CATEGORIES) do
        if found[category.label] then
            labels[#labels + 1] = category.label

            if #labels >= DEFENCE_LABEL_LIMIT then
                break
            end
        end
    end

    if #labels == 0 then
        return "NONE SEEN"
    end

    return table.concat(labels, ", ")
end

-- ============================================================================
-- Reports
-- ============================================================================

local function ReportHeader()
    return "--- TACTICAL NAVIGATION LOG ---"
end

local function VariationHeaderLine(magVar)
    if not magVar then
        return "COMPASS VARIATION: UNAVAILABLE - BEARINGS TRUE"
    end

    return string.format("COMPASS VARIATION: %+.1f\194\176", magVar)
end

local function ReportVariation(groupId)
    local unitObj = GetRequestingUnit(groupId)

    if not unitObj then
        return
    end

    local point = unitObj:getPoint()
    local magVar = GetMagVar(point)
    local lines = {ReportHeader(), ""}

    local ok, lat, lon = pcall(coord.LOtoLL, point)

    if ok and lat then
        lines[#lines + 1] = "POSITION   " .. FormatDDM(lat, lon)

        local mgrs = FormatMGRS(lat, lon)

        if mgrs then
            lines[#lines + 1] = "MGRS       " .. mgrs
        end
    end

    lines[#lines + 1] = "VARIATION  " .. FormatVariation(magVar)

    if not magVar then
        lines[#lines + 1] = "           No magnetic model available at this time."
    end

    trigger.action.outTextForGroup(groupId, table.concat(lines, "\n"), navMenuDisplayTime)
end

-- Sorts a candidate list by range and keeps the closest few. Shared by both
-- list reports so they cannot drift apart on ordering or count.
local function NearestFew(candidates)
    table.sort(candidates, function(a, b)
        if a.rangeSq ~= b.rangeSq then
            return a.rangeSq < b.rangeSq
        end

        return a.name < b.name
    end)

    while #candidates > navMenuResultCount do
        table.remove(candidates)
    end

    return candidates
end

local function ReportLandingZones(groupId)
    local unitObj = GetRequestingUnit(groupId)

    if not unitObj then
        return
    end

    local origin = unitObj:getPoint()
    local typeName = unitObj:getTypeName()
    local profile = GetProfile(typeName)
    local magVar = GetMagVar(origin)

    -- A pad is a legal destination for anything that can hover onto it: the
    -- helicopters, and the Harrier, which is fixed wing but does not need a
    -- runway. Everyone else needs an airfield.
    local padCapable = IsHelicopter(unitObj) or typeName == "AV8BNA"
    local candidates = {}

    -- Nothing here but the position lookup, which the ranking needs. Bearing,
    -- distance and threat state are all resolved after the cut.
    for _, zone in ipairs(bc:getZones() or {}) do
        local usable = zone.facility == "airbase" or (padCapable and zone.facility == "farp")

        if usable and zone.side == coalition.side.BLUE and ZoneIsVisible(zone) then
            local point = GetZonePoint(zone)

            if point then
                candidates[#candidates + 1] = {
                    name = zone.airbaseName or zone.zone,
                    -- The threat set is keyed on the zone name, which is not
                    -- the display name once an airbase has one.
                    key = zone.zone,
                    rangeSq = RangeSquared(origin, point),
                    point = point
                }
            end
        end
    end

    local lines = {ReportHeader(), "", VariationHeaderLine(magVar), "",
                   padCapable and "CLOSEST FRIENDLY LANDING ZONES:" or "CLOSEST FRIENDLY AIRFIELDS:"}

    local nearest = NearestFew(candidates)

    if #nearest == 0 then
        lines[#lines + 1] = "NONE IN RANGE - NO FRIENDLY FIELD AVAILABLE"
    else
        -- Built here rather than before the loop above: it is a second walk of
        -- every zone and every group commander on the map, and it exists to
        -- answer at most navMenuResultCount membership questions. No candidates
        -- means it never runs at all.
        local threatened = BuildThreatenedZoneSet()

        for _, entry in ipairs(nearest) do
            local bearing, range = BearingRange(origin, entry.point)

            lines[#lines + 1] = table.concat({FormatName(entry.name), threatened[entry.key] and "HOT" or "SECURE",
                                              FormatBearing(bearing, magVar), FormatDistance(range, profile),
                                              FormatPressure(entry.point, profile)}, CELL_SEPARATOR)
        end
    end

    trigger.action.outTextForGroup(groupId, table.concat(lines, "\n"), navMenuDisplayTime)
end

-- FRONT means red holds it and the fighting has reached it, REAR means it is
-- behind their lines and not yet reachable. Both are listed: a controller says
-- what is out there as well as what can be hit today. Frontline is Foothold's
-- and may not have indexed a zone, in which case the column says so rather than
-- guessing REAR and implying the zone is quiet.
local function ObjectiveStatus(zone)
    if not Frontline or not Frontline.ZoneDistToFrontNm then
        return "RED"
    end

    local ok, distance = pcall(Frontline.ZoneDistToFrontNm, zone.zone)

    if not ok or not distance then
        return "?"
    end

    return distance <= navFrontlineThresholdNm and "FRONT" or "REAR"
end

local function ReportObjectives(groupId)
    local unitObj = GetRequestingUnit(groupId)

    if not unitObj then
        return
    end

    local origin = unitObj:getPoint()
    local profile = GetProfile(unitObj:getTypeName())
    local magVar = GetMagVar(origin)
    local candidates = {}

    for _, zone in ipairs(bc:getZones() or {}) do
        if zone.side == coalition.side.RED and ZoneIsVisible(zone) then
            local point = GetZonePoint(zone)

            if point then
                candidates[#candidates + 1] = {
                    name = zone.zone,
                    rangeSq = RangeSquared(origin, point),
                    point = point,
                    zone = zone
                }
            end
        end
    end

    local lines = {ReportHeader(), "", VariationHeaderLine(magVar), "", "CLOSEST OBJECTIVES:"}

    local nearest = NearestFew(candidates)

    if #nearest == 0 then
        lines[#lines + 1] = "NO KNOWN ENEMY OBJECTIVES"
    else
        -- ObjectiveStatus and DescribeDefences are the expensive pair here: one
        -- calls into Frontline, the other walks every built group in the zone
        -- and every unit in it. Both run only on the rows being printed.
        for _, entry in ipairs(nearest) do
            local bearing, range = BearingRange(origin, entry.point)

            lines[#lines + 1] = table.concat({FormatName(entry.name), ObjectiveStatus(entry.zone),
                                              FormatBearing(bearing, magVar), FormatDistance(range, profile),
                                              FormatPressure(entry.point, profile), DescribeDefences(entry.zone)},
                CELL_SEPARATOR)
        end
    end

    trigger.action.outTextForGroup(groupId, table.concat(lines, "\n"), navMenuDisplayTime)
end

-- ============================================================================
-- Menu lifecycle
--
-- The menu's shape never changes, so unlike Foothold's dynamic menus it is
-- built once per group and left alone. Content is generated when the key is
-- pressed.
--
-- Creation is event driven, one add per player entering an aircraft. There is
-- deliberately no polling sweep: a repeating timer costs a scheduler slot for
-- the whole mission and walks every player on every tick to discover something
-- DCS already told us the instant it happened, and it makes the menu appear
-- anywhere from immediately to a full interval after the pilot slots in.
-- ============================================================================

local NAV_MENU_TITLE = "Navigation"

local nav_menus = {}

-- A report that throws must not take the scheduler or the menu down with it.
--
-- addCommandForGroup forwards exactly one argument to the handler, so the
-- reporter and the group id travel together in a table. Passing them as two
-- arguments silently drops the second and the report answers nobody.
local function SafeReport(call)
    local ok, err = pcall(call.reporter, call.groupId)

    if not ok then
        Log(env.error, "%s", tostring(err))
        trigger.action.outTextForGroup(call.groupId, "NAVIGATION: report unavailable.", 10)
    end
end

local function AddNavMenu(groupId)
    local root = missionCommands.addSubMenuForGroup(groupId, NAV_MENU_TITLE)

    missionCommands.addCommandForGroup(groupId, "Get Magnetic Variation", root, SafeReport, {
        reporter = ReportVariation,
        groupId = groupId
    })
    missionCommands.addCommandForGroup(groupId, "Get Friendly Landing Zones", root, SafeReport, {
        reporter = ReportLandingZones,
        groupId = groupId
    })
    missionCommands.addCommandForGroup(groupId, "Get Nearest Objectives", root, SafeReport, {
        reporter = ReportObjectives,
        groupId = groupId
    })

    nav_menus[groupId] = root
end

-- Rebuild rather than skip when a record already exists. DCS reuses group ids
-- as dynamic spawns come and go, so a record left behind by a previous owner
-- would make us skip a group that has no menu at all. Removing first also means
-- BIRTH and PLAYER_ENTER_UNIT both firing for one slotting cannot leave two
-- Navigation submenus stacked on the pilot's F10.
local function InstallNavMenu(groupId)
    if nav_menus[groupId] then
        pcall(missionCommands.removeItemForGroup, groupId, nav_menus[groupId])
        nav_menus[groupId] = nil
    end

    AddNavMenu(groupId)
end

-- AI births outnumber player births by a wide margin on this mission, so the
-- handler screens on the cheap fields first and only then asks for a name.
local navMenuEventHandler = {}

function navMenuEventHandler:onEvent(event)
    if not event then
        return
    end

    local id = event.id
    local entering = id == world.event.S_EVENT_BIRTH or id == world.event.S_EVENT_PLAYER_ENTER_UNIT
    local leaving = id == world.event.S_EVENT_PLAYER_LEAVE_UNIT

    if not entering and not leaving then
        return
    end

    local unitObj = event.initiator

    if not unitObj or not unitObj.getPlayerName then
        return
    end

    -- These events also carry statics and objects that are already gone, and
    -- neither has the full Unit interface. Not worth an error in the log.
    local ok, playerName = pcall(unitObj.getPlayerName, unitObj)

    if not ok or not playerName then
        return
    end

    local groupOk, groupObj = pcall(unitObj.getGroup, unitObj)

    if not groupOk or not groupObj then
        return
    end

    local idOk, groupId = pcall(groupObj.getID, groupObj)

    if not idOk or not groupId then
        return
    end

    if leaving then
        -- The group is going away and its menus with it, so there is nothing to
        -- remove; dropping the record just keeps this table from growing for
        -- the length of the mission.
        nav_menus[groupId] = nil
        return
    end

    local sideOk, side = pcall(unitObj.getCoalition, unitObj)

    if not sideOk or side ~= coalition.side.BLUE then
        return
    end

    local addOk, err = pcall(InstallNavMenu, groupId)

    if not addOk then
        Log(env.error, "could not build menu for %s: %s", tostring(playerName), tostring(err))
    end
end

-- ============================================================================
-- Arming
--
-- bc is created by the mission's setup file, which may not have run yet. Wait
-- for it rather than assuming a load order, and give up loudly instead of
-- retrying forever, so a missing battle commander reads as one error in
-- dcs.log rather than a menu that never appears for no stated reason.
-- ============================================================================

local ARM_RETRY_SECONDS = 10
local ARM_MAX_ATTEMPTS = 30

local armAttempts = 0

local function Arm(_, time)
    if not bc or not bc.getZones then
        armAttempts = armAttempts + 1

        if armAttempts >= ARM_MAX_ATTEMPTS then
            Log(env.error, "BattleCommander unavailable after %d seconds, navigation menu not armed.",
                ARM_MAX_ATTEMPTS * ARM_RETRY_SECONDS)
            return nil
        end

        return time + ARM_RETRY_SECONDS
    end

    InitMagvar()
    AuditProfileCoverage()

    Log(env.info, "%d results per report, menus built on player entering an aircraft.", navMenuResultCount)

    -- Registered only once bc is up: a report fired from a menu that existed
    -- before the battle commander did would have nothing to read.
    world.addEventHandler(navMenuEventHandler)

    -- Anyone already sitting in a seat when this armed got their birth event
    -- before the handler existed. One pass picks them up. This is a single call
    -- on arm, not a schedule: from here the menu is purely event driven.
    for _, unitObj in pairs(coalition.getPlayers(coalition.side.BLUE) or {}) do
        if unitObj and unitObj:isExist() then
            local groupObj = unitObj:getGroup()

            if groupObj and groupObj:isExist() then
                InstallNavMenu(groupObj:getID())
            end
        end
    end

    -- nil ends this timer for good. Nothing here runs on a schedule afterwards.
    return nil
end

-- Both outcomes are logged. A menu that never appears should be traceable to a
-- config switch rather than looking identical to a script that failed to load.
if navMenuEnabled then
    timer.scheduleFunction(Arm, nil, timer.getTime() + ARM_RETRY_SECONDS)
else
    Log(env.info, "disabled by config, navigation menu not armed.")
end
