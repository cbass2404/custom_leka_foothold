local travelPodPenaltyWeight = TravelPodPenaltyWeight or 1

-- ============================================================================
-- A-10 zone supply carriage
--
-- Puts the Hog into Foothold's logistics tables so the Logistics menu and its
-- Load/Unload Supplies commands appear, then charges it a travel pod's worth of
-- weight for the privilege. Not era specific: this is a cargo capability, not a
-- Cold War equipment rule.
--
-- Supplies are meant to ride in an MXU-648 travel pod, but that cannot be
-- enforced. These slots are dynamic spawns, so the jets never appear in
-- env.mission and neither the mission payload nor MOOSE's GetTemplatePylons can
-- see the chosen loadout. The only live signal found was external model draw
-- arguments 77 and 102, and testing across pods, fuel tanks, heavy bombs, a
-- clean jet and a combat load showed they report a container-sized store rather
-- than the pod itself. Worse, they latch at spawn: a pilot can spawn podded,
-- rearm the pod away, and still read as podded.
--
-- So the rule is told to the pilot rather than enforced, and backed by weight.
-- Loading supplies books a travel pod's worth of mass on top of Foothold's own
-- cargo weight, which a jet that spent its stations on ordnance will feel on the
-- takeoff roll and in the climb.
-- ============================================================================
-- Airframes that haul cargo for a living. They keep their place on Foothold's
-- carry list, but are not charged the pod weight: the mass rule exists to make
-- a jet feel a load it was never built around, and a Hercules or a Chinook
-- already accounts for it. Written as a set so the filter below is a lookup.
local exempt = {
    -- Rotary wing, transports and observation
    ["AH-64D_BLK_II"] = true,
    ["Bronco-OV-10A"] = true,
    ["C-130J-30"] = true,
    ["CH-47Fbl1"] = true,
    ["Hercules"] = true,
    ["Ka-50"] = true,
    ["Ka-50_3"] = true,
    ["Mi-24P"] = true,
    ["Mi-8MT"] = true,
    ["OH-6A"] = true,
    ["OH58D"] = true,
    ["SA342L"] = true,
    ["SA342M"] = true,
    ["SA342Minigun"] = true,
    ["SA342Mistral"] = true,
    ["UH-1H"] = true,
    ["UH-60L"] = true,
    ["UH-60L_DAP"] = true,

    -- Warbirds. No station could take an MXU-648 and the airframes are too
    -- light for the charge to read as anything but a broken jet.
    ["Bf-109K-4"] = true,
    ["F4U-1D"] = true,
    ["F4U-1D_CW"] = true,
    ["FW-190A8"] = true,
    ["FW-190D9"] = true,
    ["I-16"] = true,
    ["La-7"] = true,
    ["MosquitoFBMkVI"] = true,
    ["P-47D-30"] = true,
    ["P-47D-30bl1"] = true,
    ["P-47D-40"] = true,
    ["P-51D"] = true,
    ["P-51D-30-NA"] = true,
    ["SpitfireLFMkIX"] = true,
    ["SpitfireLFMkIXCW"] = true
}

-- Snapshot Foothold's carry list into two sets: everything it allows, and that
-- same list minus the exempt airframes. Copies rather than aliases, so the
-- writes further down cannot feed back into what is being iterated, and a
-- missing LogisticCommander falls through to the error branch at the bottom
-- instead of erroring here.
local carry_types = {}
local pod_carriage_types = {}
for typeName in pairs(LogisticCommander and LogisticCommander.AllowedToCarrySupplies or {}) do
    carry_types[typeName] = true
    if not exempt[typeName] then
        pod_carriage_types[typeName] = true
    end
end

-- 2000 lb in kilograms. setUnitInternalCargo takes kilograms and replaces the
-- unit's cargo mass outright, so Foothold's own 100 kg per supply is re-applied
-- alongside this rather than being left behind.
local POD_CARGO_WEIGHT_KG = 907 * travelPodPenaltyWeight
local FOOTHOLD_SUPPLY_WEIGHT_KG = 100

local POD_CARGO_REMINDER =
    "Supplies ride in an MXU-648 travel pod. 4000 lb is now aboard whether a pod is fitted or not, so plan the takeoff roll and climb accordingly."

-- Wrapped rather than replaced so a Foothold update keeps whatever the stock
-- loadSupplies does. LogisticCommander instances inherit through __index, so
-- patching the class reaches the live commander. This file must load after
-- zoneCommander.lua.
if LogisticCommander and LogisticCommander.loadSupplies then
    -- Foothold resolves AllowedToCarrySupplies once, when zoneCommander.lua loads,
    -- taking the config global if it exists and an internal default table if it
    -- does not. Writing to the live tables here is immune to a stale copy of the
    -- config embedded in the .miz and to the config loading after zoneCommander.
    -- allowedTypes opens the Logistics menu; AllowedToCarrySupplies puts the Load
    -- and Unload commands inside it. Both are required.
    LogisticCommander.AllowedToCarrySupplies = LogisticCommander.AllowedToCarrySupplies or {}
    for typeName in pairs(carry_types) do
        LogisticCommander.AllowedToCarrySupplies[typeName] = true
        LogisticCommander.allowedTypes[typeName] = true
    end

    -- The Load and Unload commands are also gated on legacy logistics mode, which
    -- is a separate setting. Log it so a silent menu can be told apart from a
    -- silent config.
    env.info(string.format("[A-10 Cargo]: supply carriage enabled. WarehouseLogistics=%s carry=%s",
        tostring(WarehouseLogistics), tostring(LogisticCommander.AllowedToCarrySupplies["A-10C_2"])))

    local baseLoadSupplies = LogisticCommander.loadSupplies

    function LogisticCommander:loadSupplies(groupName, supplyCount)
        local result = baseLoadSupplies(self, groupName, supplyCount)

        local group = Group.getByName(groupName)
        local unit = group and group:getUnit(1)

        if unit and pod_carriage_types[unit:getTypeName()] then
            local cargo = self.carriedCargo[group:getID()]
            local carried = 0

            if type(cargo) == "table" then
                carried = tonumber(cargo.count) or 1
            elseif cargo then
                carried = 1
            end

            -- Only charge for a load that actually happened. Foothold refuses for
            -- its own reasons, being airborne or out of zone stock among them, and
            -- leaves carriedCargo unset when it does.
            if carried > 0 then
                local mass = (carried * FOOTHOLD_SUPPLY_WEIGHT_KG) + POD_CARGO_WEIGHT_KG
                trigger.action.setUnitInternalCargo(unit:getName(), mass)
                trigger.action.outTextForGroup(group:getID(), POD_CARGO_REMINDER, 20)
                env.info(string.format("[A-10 Cargo]: %s loaded %d supplies, internal cargo set to %d kg",
                    unit:getName(), carried, mass))
            end
        end

        return result
    end
else
    env.error("[A-10 Cargo]: LogisticCommander unavailable, A-10 supply carriage not configured.")
end
