-- Extended Stats — modify R5BLProgressionTreeParams to raise MaxNodeLevel
local M = {}
local applied = false
local originals = {}

function M.apply(cfg)
    local max_level = tonumber(cfg.max_stat_level) or 250

    local all = FindAllOf("R5BLProgressionTreeParams")
    if not all then return false end

    local count = 0
    for _, obj in ipairs(all) do
        local name = obj:GetFullName()
        if name:find("Default__") then goto continue end
        if name:find("HeroStatTree") or name:find("StatTree") then
            pcall(function()
                local branches = obj.Branches
                if branches then
                    for i = 0, branches:GetArrayNum() - 1 do
                        local branch = branches:GetArrayElement(i)
                        if branch then
                            local nodes = branch.Nodes
                            if nodes then
                                for j = 0, nodes:GetArrayNum() - 1 do
                                    local node = nodes:GetArrayElement(j)
                                    if node then
                                        local addr = tostring(obj:GetAddress()) .. "_" .. i .. "_" .. j
                                        if not originals[addr] then
                                            originals[addr] = node.MaxNodeLevel or 10
                                        end
                                        node.MaxNodeLevel = max_level
                                        count = count + 1
                                    end
                                end
                            end
                        end
                    end
                end
            end)
        end
        ::continue::
    end

    if count == 0 then
        print("[SuperMod:Stats] No stat tree nodes found to modify — HeroStatTree may not be loaded")
        return false
    end

    applied = true
    print("[SuperMod:Stats] Set MaxNodeLevel=" .. max_level .. " on " .. count .. " nodes")
end

function M.revert()
    if not applied then return end
    local all = FindAllOf("R5BLProgressionTreeParams")
    if all then
        for _, obj in ipairs(all) do
            pcall(function()
                local branches = obj.Branches
                if branches then
                    for i = 0, branches:GetArrayNum() - 1 do
                        local branch = branches:GetArrayElement(i)
                        if branch and branch.Nodes then
                            for j = 0, branch.Nodes:GetArrayNum() - 1 do
                                local node = branch.Nodes:GetArrayElement(j)
                                if node then
                                    local addr = tostring(obj:GetAddress()) .. "_" .. i .. "_" .. j
                                    if originals[addr] then
                                        node.MaxNodeLevel = originals[addr]
                                    end
                                end
                            end
                        end
                    end
                end
            end)
        end
    end
    applied = false
    print("[SuperMod:Stats] Reverted max stat levels")
end

return M
