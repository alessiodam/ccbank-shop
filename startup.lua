-- os.pullEvent = os.pullEventRaw
os.loadAPI("logging")
local config = require("config")
local expect = require("cc.expect").expect

-- base routes
local BASE_CCBANK_URL = "https://ccbank.tkbstudios.com"
local BASE_CCBANK_WS_URL = "wss://ccbank.tkbstudios.com"

-- API routes
local base_api_url = BASE_CCBANK_URL .. "/api/v1"
local server_login_url = base_api_url .. "/login"
local server_balance_url = base_api_url .. "/balance"
local new_transaction_url = base_api_url .. "/transactions/new"

-- Websocket
local transactions_websocket_url = BASE_CCBANK_WS_URL .. "/websockets/transactions"

-- Session
local username = nil
local session_token = nil
local logged_in = false
local shop_balance = 0

-- Web stuff
local base_headers = {
    ["Session-Token"] = session_token
}

-- Peripherals
local monitor = peripheral.find("monitor")
local inventory
if config.USE_REFINED_STORAGE then
    inventory = peripheral.find("rsBridge")
else
    inventory = peripheral.find("inventory")
end

-- UI stuff
local prev_screen = ""
local current_screen = ""
local monitor_length, monitor_height = monitor.getSize()

-- Items stuff
local items_in_shop = {}
local items_available_in_shop = {}
local amount_of_items = 1
local total_amount_to_pay = amount_of_items
local itemPositions = {}

-- User stuff
local selected_item = nil

-- Transaction stuff
local transaction_complete = false
local username_that_paid = nil
local refund_message = nil

-- My functions
local function show_big_error(message, timeout, action_func)
    local function show_error_internal()
        monitor.setBackgroundColor(config.UI_COLORS.screens.error.background)
        monitor.setTextColor(config.UI_COLORS.screens.error.text)
        monitor.clear()
        monitor.setCursorPos(1, 1)
        monitor.write("Error: " .. message)
        os.sleep(timeout)
        if action_func then
            local action = action_func()
            if action then
                monitor.setCursorPos(1, 3)
                monitor.write(action)
            end
        end
    end
    coroutine.wrap(show_error_internal)()
end

local function get_shop_balance()
    logging.debug("Requesting shop balance")
    local response = http.get(server_balance_url, base_headers)
    if response == nil then
        logging.error("Failed to get shop balance")
        os.sleep(2)
        os.shutdown()
        return -- pure return just so that the Lua language server doesn't complain
    end
    local balance_response_content = response.readAll()
    shop_balance = tonumber(balance_response_content)
    logging.info("Shop balance: " .. shop_balance)
    return shop_balance
end

local function login()
    if string.len(config.SHOP_WALLET_USERNAME) > 15 or string.len(config.SHOP_WALLET_PIN) > 8 or string.len(config.SHOP_WALLET_USERNAME) < 3 or string.len(config.SHOP_WALLET_PIN) < 4 then
        return {success = false, message = "Invalid username or PIN length"}
    end

    local postData = {
        username = config.SHOP_WALLET_USERNAME,
        pin = config.SHOP_WALLET_PIN
    }
    local postHeaders = {
        ["Content-Type"] = "application/json"
    }
    local response = http.post(server_login_url, textutils.serializeJSON(postData), postHeaders)
    if not response then
        logging.error("Login request failed")
        os.sleep(2)
        os.shutdown()
        return -- pure return just so that the Lua language server doesn't complain
    end

    local responseBody = response.readAll()
    if not responseBody then
        logging.error("Login response is empty")
        os.sleep(2)
        os.shutdown()
    end

    local decodedResponse, decodeError = textutils.unserializeJSON(responseBody)
    if not decodedResponse then
        logging.error("decoding login response JSON: " .. (decodeError or "Unknown"))
        os.sleep(2)
        os.shutdown()
    end

    if decodedResponse.success then
        session_token = decodedResponse.session_token
        logged_in = true
        logging.success("Logged in successfully as " .. config.SHOP_WALLET_USERNAME)
        base_headers["Session-Token"] = session_token
        get_shop_balance()
    else
        logging.error("Login failed for user '" .. username .. "': " .. decodedResponse.message)
        os.sleep(2)
        os.shutdown()
    end

    return true
end

local function create_transaction(target_username, amount)
    if string.len(target_username) > 15 or amount <= 0 then
        return {success = false, message = "Invalid target username or amount"}
    end

    local headers = {
        ["Content-Type"] = "application/json",
        ["Session-Token"] = session_token
    }

    local postData = {
        username = target_username,
        amount = amount
    }

    local response = http.post(new_transaction_url, textutils.serializeJSON(postData), headers)
    if not response then
        return {success = false, message = "Failed to connect to server"}
    end

    local responseBody = response.readAll()
    if not responseBody then
        return {success = false, message = "Empty response from server"}
    end

    local decodedResponse, decodeError = textutils.unserializeJSON(responseBody)
    if not decodedResponse then
        return {success = false, message = "Failed to parse server response"}
    end

    return decodedResponse
end

local function fetchItems()
    local items_in_shop_count = {}

    if config.USE_REFINED_STORAGE then
        local items_in_refined_storage = inventory.listItems()
        -- example item:
        -- {"name":"minecraft:emerald","amount":128,"fingerprint":"3947F0CBE47497719B71A1404D27798D","tags":["minecraft:item/minecraft:beacon_payment_items","minecraft:item/minecraft:trim_materials","minecraft:item/forge:gems/emerald","minecraft:item/forge:gems","minecraft:item/balm:gems","minecraft:item/balm:emeralds"],"isCraftable":false,"displayName":"[Emerald]"}
        for _, v in ipairs(items_in_refined_storage) do
            items_available_in_shop[v.name] = v.amount
            logging.debug("Found item: " .. v.name .. " count: " .. v.amount)
        end
        logging.debug("Fetched items from refined storage")
    else
        logging.debug("Fetching items from inventory")
        items_in_shop = inventory.list()
        for _, item in ipairs(items_in_shop) do
            logging.debug("Found item: " .. item.name .. " count: " .. item.count)
            if items_in_shop_count[item.name] == nil then
                items_in_shop_count[item.name] = item.count
            else
                items_in_shop_count[item.name] = items_in_shop_count[item.name] + item.count
            end
        end

        items_available_in_shop = {}
        for name, count in pairs(items_in_shop_count) do
            items_available_in_shop[name] = count
            logging.debug("Adding item to available items: " .. name .. " count: " .. count)
        end
        logging.info("Fetched items from inventory")
    end

end

local function getPriceFromItem(item)
    expect(1, item, "string")
    local item_price = config.PRICES[item]
    if item_price == nil then
        logging.warning("No price found for item: " .. item)
    end
    return item_price
end

local function get_amount_of_items_available(item)
    expect(1, item, "string")
    fetchItems()
    return items_available_in_shop[item]
end

local function purchaseCompleteScreen()
    monitor.setBackgroundColor(config.UI_COLORS.screens.purchase_complete.background)
    monitor.setTextColor(config.UI_COLORS.screens.purchase_complete.text)
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.setTextScale(2)
    monitor.write("Purchased " .. selected_item)
    monitor.setCursorPos(1, 3)
    monitor.write("for " .. total_amount_to_pay .. "$")
    monitor.setCursorPos(1, 3)
    monitor.write("Thank you, " .. username_that_paid .. "!")
    if refund_message ~= nil then
        monitor.setCursorPos(1, 5)
        monitor.write(refund_message)
    end
    monitor.setCursorPos(1, 10)
    monitor.write("Press anywhere to go home")
    selected_item = ""
    amount_of_items = 1
    total_amount_to_pay = 0
    refund_message = nil
    return "main"
end

local function purchasingScreen()
    transaction_complete = false
    local timeouts = 0
    username_that_paid = nil

    monitor.setBackgroundColor(config.UI_COLORS.screens.default.background)
    monitor.setTextColor(config.UI_COLORS.screens.default.text)
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.setTextScale(2)
    monitor.write("Purchasing")
    monitor.setCursorPos(1, 2)
    monitor.clearLine()
    monitor.write("Available: " .. get_amount_of_items_available(selected_item))
    monitor.setCursorPos(1, 3)
    monitor.clearLine()
    monitor.write("Amount: " .. amount_of_items)
    monitor.setCursorPos(1, 4)
    monitor.clearLine()
    monitor.write("Subtotal: " .. total_amount_to_pay .. "$")

    monitor.setCursorPos(1, 6)
    monitor.write("Please send " .. total_amount_to_pay)
    monitor.setCursorPos(1, 7)
    monitor.write("to " .. config.SHOP_WALLET_USERNAME .. " in the next " .. config.TRANSACTION_TIMEOUT .. " seconds")
    monitor.setCursorPos(1, 8)
    monitor.write("using Bank Of ComputerCraft")

    local transactions_ws, ws_error_msg = http.websocket(transactions_websocket_url, base_headers)
    if not transactions_ws then
        logging.error("Failed to open websocket: " .. (ws_error_msg or "Unknown"))
        os.sleep(2)
        os.shutdown()
        return -- so that lua language server doesn't complain
    else
        logging.success("Websocket opened successfully")
    end

    local timer_id = os.startTimer(1)
    local event, id, message
    while timeouts < config.TRANSACTION_TIMEOUT do
        event, id, message = os.pullEvent()
        if event == "timer" and id == timer_id then
            timeouts = timeouts + 1
            local left_time = config.TRANSACTION_TIMEOUT - timeouts

            if (left_time % 2 == 0) then
                monitor.setBackgroundColor(colors.white)
                monitor.setTextColor(colors.black)
            else
                monitor.setBackgroundColor(colors.black)
                monitor.setTextColor(colors.white)
            end

            monitor.setCursorPos(1, 7)
            monitor.write("to " .. config.SHOP_WALLET_USERNAME .. " in the next " .. left_time .. " seconds     ")
            
            if (timeouts % 5 == 0) then
                logging.info("Timeouts: " .. timeouts)
            end
            timer_id = os.startTimer(1)
        elseif event == "websocket_message" then
            local transaction_json = textutils.unserializeJSON(message)
            username_that_paid = transaction_json.from_user
            
            -- If the transaction is to the shop's wallet
            if transaction_json.to_user == config.SHOP_WALLET_USERNAME then
                if transaction_json.amount >= total_amount_to_pay then
                    local extra_money = transaction_json.amount - total_amount_to_pay
                    if extra_money > 0 then
                        -- If there is extra money, create a refund transaction
                        logging.warning(username_that_paid .. " paid too much (" .. transaction_json.amount .. " vs " .. total_amount_to_pay .. "), giving him a refund for the rest of the coins.")
                        local transaction_response = create_transaction(username_that_paid, extra_money) -- Create the refund transaction
                        if transaction_response.success then
                            refund_message = "You've got a refund of " .. extra_money .. "$"
                            logging.success("refund success, transaction ID: " .. transaction_response.transaction_id)
                        else
                            refund_message = "Failed to refund " .. extra_money .. "$"
                            logging.error(textutils.serializeJSON(transaction_response))
                        end
                        logging.debug(textutils.serializeJSON(transaction_response))
                    end
                    logging.success("Transaction successful from " .. username_that_paid)
                    transaction_complete = true
                    shop_balance = shop_balance + total_amount_to_pay
                    logging.debug("Exporting items")
                    if config.USE_REFINED_STORAGE then
                        inventory.exportItem({name=selected_item, count=amount_of_items}, "up")
                    end
                    break
                elseif transaction_json.amount > 0 and transaction_json.amount < total_amount_to_pay then
                    -- If the amount is incorrect, create a refund transaction for the amount paid
                    logging.warning("Transaction amount mismatch: " .. transaction_json.amount .. " vs " .. total_amount_to_pay .. " from " .. transaction_json.from_user)
                    local transaction_response = create_transaction(username_that_paid, transaction_json.amount)
                    if transaction_response.success then
                        logging.success("refund success, transaction ID: " .. transaction_response.transaction_id)
                    else
                        logging.error(textutils.serializeJSON(transaction_response))
                    end
                end
            end
        end
    end
    transactions_ws.close()
    logging.info("Closed websocket")
    -- Check if the transaction is complete
    if transaction_complete then
        -- If the transaction is complete, return to the purchase_complete screen
        logging.success("Transaction complete for " .. username_that_paid)
        return "purchase_complete"
    else
        -- If the transaction timed out, return to the main screen
        -- TODO: make a transaction timed out screen
        logging.error("Transaction timed out")
        -- current_screen = "purchase_timed_out"
        return "main"
    end

end


local function purchaseScreen()
    total_amount_to_pay = amount_of_items * getPriceFromItem(selected_item)
    monitor.setBackgroundColor(config.UI_COLORS.screens.default.background)
    monitor.setTextColor(config.UI_COLORS.screens.default.text)
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.setTextScale(2)
    monitor.write("Purchasing")
    monitor.setCursorPos(1, 2)
    monitor.clearLine()
    monitor.write(selected_item)
    monitor.setCursorPos(1, 3)
    monitor.clearLine()
    monitor.write("Available: " .. get_amount_of_items_available(selected_item))
    monitor.setCursorPos(1, 4)
    monitor.clearLine()
    monitor.write("Amount: " .. amount_of_items)
    monitor.setCursorPos(1, 5)
    monitor.clearLine()
    monitor.write("Subtotal: " .. total_amount_to_pay .. "$")

    -- Buttons
    monitor.setCursorPos(2, 7)
    monitor.write("-10")
    monitor.setCursorPos(11, 7)
    monitor.write("-1")
    monitor.setCursorPos(19, 7)
    monitor.write("+1")
    monitor.setCursorPos(27, 7)
    monitor.write("+10")
    monitor.setCursorPos(1, 13)
    monitor.setBackgroundColor(config.UI_COLORS.buttons.back.background)
    monitor.setTextColor(config.UI_COLORS.buttons.back.text)
    monitor.write("< Back")

    -- Big buy button
    monitor.setBackgroundColor(config.UI_COLORS.buttons.buy.background)
    monitor.setTextColor(config.UI_COLORS.buttons.buy.text)
    monitor.setCursorPos(monitor_length - 6, 13)
    monitor.write("BUY NOW")
    monitor.setBackgroundColor(config.UI_COLORS.screens.default.background)
    monitor.setTextColor(config.UI_COLORS.screens.default.text)
    return "purchase"
end

local function mainScreen()
    monitor.setBackgroundColor(config.UI_COLORS.screens.default.background)
    monitor.setTextColor(config.UI_COLORS.screens.default.text)
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.setTextScale(2)
    monitor.write("CC Bank Shop")
    monitor.setCursorPos(1, 5)
    fetchItems()

    local y = 3
    for name, _ in pairs(items_available_in_shop) do
        local colonIndex = name:find(":")
        local item_name_clean = name:sub(colonIndex + 1)
        local item_price = getPriceFromItem(name)
        if item_price then
            monitor.setCursorPos(1, y)
            monitor.write(item_name_clean .. " - " .. item_price .. "$")
            itemPositions[y] = name
            y = y + 1
        end
    end
    return "main"
end


local function handleClicks()
    if current_screen == "main" then
        local event, _, x, y = os.pullEvent("monitor_touch")
        local itemName = itemPositions[y]
        if itemName == nil then
            logging.warning("No item at " .. x .. ", " .. y)
            return
        end
        logging.debug("Touch at " .. x .. ", " .. y .. " on " .. itemName)
        selected_item = itemName
        return "purchase"
    elseif current_screen == "purchase" then
        local _, _, x, y = os.pullEvent("monitor_touch")
        if y == 7 then
            if x >= 2 and x <= 10 and amount_of_items - 10 > 0 then
                amount_of_items = amount_of_items - 10
                total_amount_to_pay = amount_of_items * getPriceFromItem(selected_item)
            elseif x == 11 and amount_of_items - 1 > 0 then
                amount_of_items = amount_of_items - 1
                total_amount_to_pay = amount_of_items * getPriceFromItem(selected_item)
            elseif x == 19  and amount_of_items + 1 <= 64 and amount_of_items + 1 <= get_amount_of_items_available(selected_item) then
                amount_of_items = amount_of_items + 1
                total_amount_to_pay = amount_of_items * getPriceFromItem(selected_item)
            elseif x == 27 and amount_of_items + 10 <= 64 and amount_of_items + 10 <= get_amount_of_items_available(selected_item) then
                amount_of_items = amount_of_items + 10
                total_amount_to_pay = amount_of_items * getPriceFromItem(selected_item)
            end
        elseif y == 13 and x >= monitor_length - 7 then
            logging.debug("Performing purchase for " .. amount_of_items .. " of " .. selected_item)
            return "purchasing"
        elseif y == 13 and x >= 1 and x <= 6 then
            return "main"
        end
        monitor.setCursorPos(1, 1)
        monitor.setTextScale(2)
        monitor.write("Purchasing")
        monitor.setCursorPos(1, 2)
        monitor.clearLine()
        monitor.write(selected_item)
        monitor.setCursorPos(1, 3)
        monitor.clearLine()
        monitor.write("Available: " .. get_amount_of_items_available(selected_item))
        monitor.setCursorPos(1, 4)
        monitor.clearLine()
        monitor.write("Amount: " .. amount_of_items)
        monitor.setCursorPos(1, 5)
        monitor.clearLine()
        monitor.write("Subtotal: " .. total_amount_to_pay .. "$")
    end
    return current_screen
end

local function main()
    -- Login
    logging.info("Logging in")
    login()

    -- Main loop
    logging.info("Main loop")
    current_screen = "main"
    while true do
        if prev_screen ~= current_screen then
            prev_screen = current_screen
            logging.debug("change screen to " .. current_screen)
            if current_screen == "main" then
                current_screen = mainScreen()
            elseif current_screen == "purchase" then
                current_screen = purchaseScreen()
            elseif current_screen == "purchasing" then
                current_screen = purchasingScreen()
            elseif current_screen == "purchase_complete" then
                current_screen = purchaseCompleteScreen()
            else
                logging.warning("Invalid screen: " .. current_screen)
            end
        end
        current_screen = handleClicks() or "main"
        os.sleep(0.01)
    end
end

term.clear()
term.setCursorPos(1, 1)
print("BoCC Shop")
logging.init(1, true, "log.txt")
logging.info("Init")

local success, result = pcall(main)

if not success then
    if result == "Terminated" then
        logging.warning("Terminated, exiting.")
        return
    end
    logging.error("Error: " .. result)
    logging.error(debug.traceback())
    os.sleep(0.5)
    os.reboot()
end
