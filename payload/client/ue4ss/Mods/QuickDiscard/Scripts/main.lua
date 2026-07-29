local function UpdateInventoryUI()
    ExecuteInGameThread(function()
        for _, b in ipairs(FindAllOf("TextBlock") or {}) do
            if b:GetText():ToString():upper() == "DROP" then
                b:SetText(FText("DELETE"))
            end
        end
    end)
end

RegisterHook("/Script/R5.R5DefaultInventoryVM:OnVirtualSlotUpdated", UpdateInventoryUI)

local IsArmed = false

RegisterHook("/Script/R5.R5DefaultInventoryVM:DropItemsFromDrag", function()
    IsArmed = true
end)

NotifyOnNewObject("/Script/R5.R5LootActor", function(L)
    if IsArmed and L:IsValid() then L:K2_DestroyActor() IsArmed = false end
end)