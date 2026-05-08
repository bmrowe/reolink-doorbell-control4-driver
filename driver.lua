OPC = OPC or {}
EC = EC or {}
OCS = OCS or {}
RFN = RFN or {}
RUNTIME = RUNTIME or {}
REOLINK = REOLINK or {}
BIT = bit32 or bit

do
    DEFAULT_NETBINDING = 6001
    BAICHUAN_HEADER_MAGIC = "f0debc0a"
    BAICHUAN_XML_KEY = {0x1F, 0x2D, 0x3C, 0x4B, 0x5A, 0x69, 0x78, 0xFF}

    PROPERTY_DEBUG_MODE = "Debug Mode"
    PROPERTY_DOORBELL_IP = "Doorbell IP"
    PROPERTY_API_PORT = "API Port"
    PROPERTY_USE_HTTPS = "Use HTTPS"
    PROPERTY_BAICHUAN_PORT = "Baichuan Port"
    PROPERTY_USERNAME = "Username"
    PROPERTY_PASSWORD = "Password"
    PROPERTY_CHANNEL = "Channel"
    PROPERTY_DEBOUNCE_SECONDS = "Debounce Seconds"
    PROPERTY_PUSH_SETTLING_DELAY_MS = "Push Settling Delay MS"
    PROPERTY_POLL_FALLBACK_SECONDS = "Poll Fallback Seconds"
    PROPERTY_CONNECTION_STATUS = "Connection Status"
    PROPERTY_LAST_PUSH_TIMESTAMP = "Last Push Timestamp"
    PROPERTY_LAST_VISITOR_EVENT = "Last Visitor Event"
    PROPERTY_LAST_REFRESH_RESULT = "Last Refresh Result"
    VARIABLE_LAST_VISITOR_EVENT = "LAST_VISITOR_EVENT"
    VARIABLE_CONNECTION_STATUS = "CONNECTION_STATUS"
    VARIABLE_LAST_PUSH_TIMESTAMP = "LAST_PUSH_TIMESTAMP"
    RECONNECT_DELAY_MS = 10000
    HTTP_WATCHDOG_MS = 15000
    BAICHUAN_PENDING_MAX_AGE_MS = 60000
    BAICHUAN_MAX_FRAME_BYTES = 262144
end

local function now_ms()
    if C4 and C4.GetTime then
        return C4:GetTime()
    end
    return os.time() * 1000
end

local function now_string()
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function hex_to_bytes(hex)
    return (hex:gsub("..", function(cc)
        return string.char(tonumber(cc, 16))
    end))
end

local function bytes_to_hex(data, max_len)
    if not data then
        return ""
    end
    local s = {}
    local limit = math.min(#data, max_len or #data)
    for i = 1, limit do
        s[#s + 1] = string.format("%02x", string.byte(data, i))
    end
    return table.concat(s)
end

local function little_endian_bytes(value, length)
    local out = {}
    local n = tonumber(value) or 0
    for _ = 1, length do
        out[#out + 1] = string.char(n % 256)
        n = math.floor(n / 256)
    end
    return table.concat(out)
end

local function little_endian_u32(data, index)
    local b1 = string.byte(data, index) or 0
    local b2 = string.byte(data, index + 1) or 0
    local b3 = string.byte(data, index + 2) or 0
    local b4 = string.byte(data, index + 3) or 0
    return b1 + (b2 * 256) + (b3 * 65536) + (b4 * 16777216)
end

local function json_escape(value)
    value = tostring(value or "")
    value = string.gsub(value, "\\", "\\\\")
    value = string.gsub(value, '"', '\\"')
    value = string.gsub(value, "\r", "\\r")
    value = string.gsub(value, "\n", "\\n")
    value = string.gsub(value, "\t", "\\t")
    return value
end

local function dbg(message)
    if Properties and Properties[PROPERTY_DEBUG_MODE] == "On" then
        print("Reolink Doorbell: " .. tostring(message))
    end
end

local function info(message)
    print("Reolink Doorbell: " .. tostring(message))
end

local function warn(message)
    print("Reolink Doorbell WARN: " .. tostring(message))
end

local function update_property(name, value)
    if C4 and C4.UpdateProperty then
        C4:UpdateProperty(name, tostring(value))
    end
end

local function ensure_variable(name, default_value, value_type)
    if not Variables or Variables[name] then
        return
    end
    C4:AddVariable(name, tostring(default_value), value_type, true, false)
end

local function set_variable(name, value)
    if C4 and C4.SetVariable then
        C4:SetVariable(name, value)
    end
end

local function ensure_programming_variables()
    ensure_variable(VARIABLE_LAST_VISITOR_EVENT, "Never", "STRING")
    ensure_variable(VARIABLE_CONNECTION_STATUS, "Disconnected", "STRING")
    ensure_variable(VARIABLE_LAST_PUSH_TIMESTAMP, "Never", "STRING")
end

local function sanitize_property_name(name)
    return string.gsub(name, "%s+", "_")
end

local function ensure_runtime_defaults()
    RUNTIME.config = RUNTIME.config or {}
    RUNTIME.connected = RUNTIME.connected or false
    RUNTIME.connection_lost_fired = RUNTIME.connection_lost_fired or false
    RUNTIME.push_buffer = RUNTIME.push_buffer or ""
    RUNTIME.last_push_ms = RUNTIME.last_push_ms or 0
    RUNTIME.last_visitor_event_ms = RUNTIME.last_visitor_event_ms or 0
    RUNTIME.visitor_state = RUNTIME.visitor_state
    RUNTIME.token = RUNTIME.token or nil
    RUNTIME.token_expiry_ms = RUNTIME.token_expiry_ms or 0
    RUNTIME.login_in_flight = RUNTIME.login_in_flight or false
    RUNTIME.refresh_in_flight = RUNTIME.refresh_in_flight or false
    RUNTIME.pending_refresh_reason = RUNTIME.pending_refresh_reason or nil
    RUNTIME.refresh_burst_active = RUNTIME.refresh_burst_active or false
    RUNTIME.initializing_properties = RUNTIME.initializing_properties or false
    RUNTIME.shutting_down = RUNTIME.shutting_down or false
    RUNTIME.reconnect_timer = RUNTIME.reconnect_timer or nil
    RUNTIME.login_watchdog_timer = RUNTIME.login_watchdog_timer or nil
    RUNTIME.refresh_watchdog_timer = RUNTIME.refresh_watchdog_timer or nil
    RUNTIME.baichuan = RUNTIME.baichuan or {}
    RUNTIME.baichuan.buffer = RUNTIME.baichuan.buffer or ""
    RUNTIME.baichuan.pending = RUNTIME.baichuan.pending or {}
    RUNTIME.baichuan.mess_id = RUNTIME.baichuan.mess_id or 0
    RUNTIME.baichuan.logged_in = RUNTIME.baichuan.logged_in or false
    RUNTIME.baichuan.subscribed = RUNTIME.baichuan.subscribed or false
    RUNTIME.baichuan.nonce = RUNTIME.baichuan.nonce or nil
    RUNTIME.baichuan.keepalive_timer = RUNTIME.baichuan.keepalive_timer or nil
    RUNTIME.baichuan.login_state = RUNTIME.baichuan.login_state or "idle"
    RUNTIME.state_refresh_timer = RUNTIME.state_refresh_timer or nil
    RUNTIME.poll_timer = RUNTIME.poll_timer or nil
end

local function refresh_config()
    RUNTIME.config.host = Properties[PROPERTY_DOORBELL_IP] or ""
    RUNTIME.config.api_port = tonumber(Properties[PROPERTY_API_PORT]) or 443
    RUNTIME.config.use_https = (Properties[PROPERTY_USE_HTTPS] or "Yes") == "Yes"
    RUNTIME.config.baichuan_port = tonumber(Properties[PROPERTY_BAICHUAN_PORT]) or 9000
    RUNTIME.config.username = Properties[PROPERTY_USERNAME] or "admin"
    RUNTIME.config.password = Properties[PROPERTY_PASSWORD] or ""
    RUNTIME.config.channel = tonumber(Properties[PROPERTY_CHANNEL]) or 0
    RUNTIME.config.debounce_seconds = tonumber(Properties[PROPERTY_DEBOUNCE_SECONDS]) or 3
    RUNTIME.config.push_settling_delay_ms = tonumber(Properties[PROPERTY_PUSH_SETTLING_DELAY_MS]) or 250
    RUNTIME.config.poll_fallback_seconds = tonumber(Properties[PROPERTY_POLL_FALLBACK_SECONDS]) or 5
end

local function has_minimum_config()
    return RUNTIME.config.host ~= "" and RUNTIME.config.username ~= "" and RUNTIME.config.password ~= ""
end

local function cancel_timer(name)
    if RUNTIME[name] then
        RUNTIME[name]:Cancel()
        RUNTIME[name] = nil
    end
end

local function cancel_baichuan_keepalive()
    if RUNTIME.baichuan and RUNTIME.baichuan.keepalive_timer then
        RUNTIME.baichuan.keepalive_timer:Cancel()
        RUNTIME.baichuan.keepalive_timer = nil
    end
end

local clear_http_watchdog
local start_poll_timer

local function reset_http_session()
    RUNTIME.token = nil
    RUNTIME.token_expiry_ms = 0
    RUNTIME.login_in_flight = false
    RUNTIME.refresh_in_flight = false
    RUNTIME.pending_refresh_reason = nil
    clear_http_watchdog("login_watchdog_timer")
    clear_http_watchdog("refresh_watchdog_timer")
end

local function restart_poll_timer_if_running()
    if RUNTIME.poll_timer then
        start_poll_timer()
    end
end

local function stop_poll_timer()
    cancel_timer("poll_timer")
end

local function schedule_reconnect()
    cancel_timer("reconnect_timer")
    RUNTIME.reconnect_timer = C4:SetTimer(RECONNECT_DELAY_MS, function()
        RUNTIME.reconnect_timer = nil
        if not RUNTIME.connected and has_minimum_config() then
            info("Automatic reconnect attempt")
            REOLINK.OpenConnection()
        end
    end, false)
end

local function start_http_watchdog(timer_name, flag_name, label)
    cancel_timer(timer_name)
    RUNTIME[timer_name] = C4:SetTimer(HTTP_WATCHDOG_MS, function()
        RUNTIME[timer_name] = nil
        if RUNTIME[flag_name] then
            RUNTIME[flag_name] = false
            warn(label .. " watchdog expired; clearing in-flight flag")
        end
    end, false)
end

clear_http_watchdog = function(timer_name)
    cancel_timer(timer_name)
end

local function base_url()
    local scheme = RUNTIME.config.use_https and "https" or "http"
    return scheme .. "://" .. tostring(RUNTIME.config.host) .. ":" .. tostring(RUNTIME.config.api_port) .. "/cgi-bin/api.cgi"
end

local function token_is_valid()
    return RUNTIME.token ~= nil and (tonumber(RUNTIME.token_expiry_ms) or 0) > (now_ms() + 60000)
end

local function parse_json(raw)
    local ok, decoded = pcall(function()
        return C4:JsonDecode(raw)
    end)
    if not ok then
        return nil, decoded
    end
    return decoded, nil
end

local schedule_state_refresh
local set_refresh_result

local function c4_md5_modern(value)
    local hash = C4:Hash("md5", value, { ["return_encoding"] = "HEX" })
    return string.upper(tostring(hash or ""))
end

local function baichuan_encrypt(buf, offset)
    local parts = {}
    local enc_offset = (tonumber(offset) or 0) % 256
    for i = 1, #buf do
        local byte = string.byte(buf, i)
        local key = BAICHUAN_XML_KEY[((enc_offset + (i - 1)) % #BAICHUAN_XML_KEY) + 1]
        parts[#parts + 1] = string.char(BIT.bxor(byte, key, enc_offset))
    end
    return table.concat(parts)
end

local function baichuan_decrypt(buf, offset)
    return baichuan_encrypt(buf, offset)
end

local function baichuan_full_mess_id(ch_id, mess_id)
    return (tonumber(ch_id) or 0) + ((tonumber(mess_id) or 0) * 256)
end

local function baichuan_next_mess_id()
    RUNTIME.baichuan.mess_id = ((tonumber(RUNTIME.baichuan.mess_id) or 0) + 1) % 16777216
    return RUNTIME.baichuan.mess_id
end

local function baichuan_build_packet(cmd_id, opts)
    opts = opts or {}
    local ch_id = opts.ch_id
    if ch_id == nil then
        ch_id = 250
    end
    local mess_id = opts.mess_id or baichuan_next_mess_id()
    local message_class = opts.message_class or "1464"
    local body = opts.body or ""
    local extension = opts.extension or ""
    local enc_type = opts.enc_type or "bc"
    local message_length = #extension + #body
    local payload_offset = #extension

    local header = hex_to_bytes(BAICHUAN_HEADER_MAGIC)
        .. little_endian_bytes(cmd_id, 4)
        .. little_endian_bytes(message_length, 4)
        .. string.char(ch_id)
        .. little_endian_bytes(mess_id, 3)

    if message_class == "1465" then
        header = header .. hex_to_bytes("12dc1465")
    else
        header = header .. hex_to_bytes("00001464") .. little_endian_bytes(payload_offset, 4)
    end

    local body_bytes = ""
    if message_length > 0 then
        if enc_type ~= "bc" then
            error("Only Baichuan body encoding is implemented in Milestone 6")
        end
        body_bytes = baichuan_encrypt(extension, ch_id) .. baichuan_encrypt(body, ch_id)
    end

    return {
        packet = header .. body_bytes,
        ch_id = ch_id,
        mess_id = mess_id,
        full_mess_id = baichuan_full_mess_id(ch_id, mess_id),
        cmd_id = cmd_id,
        enc_type = enc_type,
        message_class = message_class,
    }
end

local function baichuan_parse_xml_value(xml, key)
    if not xml or not key then
        return nil
    end
    local pattern = "<" .. key .. ">(.-)</" .. key .. ">"
    return string.match(xml, pattern)
end

local function baichuan_send_command(cmd_id, opts, callback)
    local built = baichuan_build_packet(cmd_id, opts)
    RUNTIME.baichuan.pending[cmd_id] = RUNTIME.baichuan.pending[cmd_id] or {}
    RUNTIME.baichuan.pending[cmd_id][built.full_mess_id] = {
        callback = callback,
        enc_type = built.enc_type,
        created_ms = now_ms(),
    }

    dbg(
        "Baichuan send cmd_id="
            .. tostring(cmd_id)
            .. " ch_id="
            .. tostring(built.ch_id)
            .. " mess_id="
            .. tostring(built.full_mess_id)
            .. " bytes="
            .. tostring(#built.packet)
    )
    C4:SendToNetwork(DEFAULT_NETBINDING, RUNTIME.config.baichuan_port, built.packet)
end

local function baichuan_gc_pending()
    local now = now_ms()
    for cmd_id, by_message in pairs(RUNTIME.baichuan.pending) do
        for full_mess_id, entry in pairs(by_message) do
            if now - (tonumber(entry.created_ms) or 0) > BAICHUAN_PENDING_MAX_AGE_MS then
                dbg("Discarding stale Baichuan pending request cmd_id=" .. tostring(cmd_id) .. " mess_id=" .. tostring(full_mess_id))
                by_message[full_mess_id] = nil
            end
        end
        if not next(by_message) then
            RUNTIME.baichuan.pending[cmd_id] = nil
        end
    end
end

local function baichuan_start_keepalive()
    cancel_baichuan_keepalive()
    RUNTIME.baichuan.keepalive_timer = C4:SetTimer(30000, function()
        if not RUNTIME.connected or not RUNTIME.baichuan.subscribed then
            return
        end
        baichuan_gc_pending()
        dbg("Sending Baichuan keepalive")
        baichuan_send_command(93, { ch_id = 250, message_class = "1464" }, function(response)
            dbg("Baichuan keepalive acknowledged")
        end)
    end, true)
end

local function baichuan_subscribe()
    dbg("Subscribing to Baichuan events")
    baichuan_send_command(31, { ch_id = 251, message_class = "1464" }, function(response)
        RUNTIME.baichuan.subscribed = true
        dbg("Baichuan subscribe acknowledged")
        stop_poll_timer()
        baichuan_start_keepalive()
        schedule_state_refresh("baichuan_subscribed")
    end)
end

local function baichuan_login()
    local nonce = RUNTIME.baichuan.nonce
    if not nonce then
        warn("Baichuan login requested without nonce")
        return
    end

    local username_hash = c4_md5_modern((RUNTIME.config.username or "") .. nonce)
    local password_hash = c4_md5_modern((RUNTIME.config.password or "") .. nonce)
    local xml =
        '<?xml version="1.0" encoding="UTF-8" ?>\n'
        .. "<body>\n"
        .. "<LoginUser version=\"1.1\">\n"
        .. "<userName>" .. username_hash .. "</userName>\n"
        .. "<password>" .. password_hash .. "</password>\n"
        .. "<userVer>1</userVer>\n"
        .. "</LoginUser>\n"
        .. "<LoginNet version=\"1.1\">\n"
        .. "<type>LAN</type>\n"
        .. "<udpPort>0</udpPort>\n"
        .. "</LoginNet>\n"
        .. "</body>\n"

    dbg("Sending Baichuan modern login")
    baichuan_send_command(1, { ch_id = 250, body = xml, enc_type = "bc", message_class = "1464" }, function(response)
        RUNTIME.baichuan.logged_in = true
        RUNTIME.baichuan.login_state = "logged_in"
        dbg("Baichuan modern login acknowledged")
        baichuan_subscribe()
    end)
end

local function baichuan_request_nonce()
    RUNTIME.baichuan.login_state = "nonce"
    dbg("Requesting Baichuan nonce")
    baichuan_send_command(1, { ch_id = 250, message_class = "1465", enc_type = "bc" }, function(response)
        local nonce = baichuan_parse_xml_value(response.body, "nonce")
        if not nonce then
            warn("Baichuan nonce missing in response")
            return
        end
        RUNTIME.baichuan.nonce = nonce
        dbg("Baichuan nonce received")
        baichuan_login()
    end)
end

local function baichuan_clear_session()
    RUNTIME.baichuan.buffer = ""
    RUNTIME.baichuan.pending = {}
    RUNTIME.baichuan.logged_in = false
    RUNTIME.baichuan.subscribed = false
    RUNTIME.baichuan.nonce = nil
    RUNTIME.baichuan.login_state = "idle"
    RUNTIME.refresh_burst_active = false
    cancel_baichuan_keepalive()
end

local function baichuan_handle_unsolicited(cmd_id, full_mess_id, body, payload)
    dbg(
        "Baichuan unsolicited message cmd_id="
            .. tostring(cmd_id)
            .. " mess_id="
            .. tostring(full_mess_id)
            .. " body_len="
            .. tostring(#body or 0)
            .. " payload_len="
            .. tostring(#payload or 0)
    )
    if cmd_id ~= 33 then
        dbg("Ignoring unsolicited cmd_id=" .. tostring(cmd_id) .. " for refresh triggering")
        return
    end
    if not RUNTIME.refresh_burst_active then
        RUNTIME.refresh_burst_active = true
        cancel_timer("state_refresh_timer")

        local burst_reason = "baichuan_push_" .. tostring(cmd_id)
        local delays = {50, 250, 1000}
        local burst_index = 1

        local function queue_next()
            local delay_ms = delays[burst_index]
            if delay_ms == nil then
                RUNTIME.refresh_burst_active = false
                return
            end

            local ok, timer_or_err = pcall(function()
                return C4:SetTimer(delay_ms, function()
                    set_refresh_result("Burst refresh " .. tostring(burst_index) .. " from " .. burst_reason)
                    REOLINK.RefreshVisitorState(burst_reason .. "_burst" .. tostring(burst_index))
                    burst_index = burst_index + 1
                    queue_next()
                end, false)
            end)

            if ok then
                RUNTIME.state_refresh_timer = timer_or_err
            else
                RUNTIME.refresh_burst_active = false
                warn("Failed to schedule refresh burst timer: " .. tostring(timer_or_err))
            end
        end

        queue_next()
    else
        dbg("Refresh burst already active; keeping existing burst for cmd_id=" .. tostring(cmd_id))
    end
end

local function baichuan_process_chunk(chunk)
    local data = chunk
    local total = #data
    if total < 20 then
        return nil, "need_more"
    end

    local cmd_id = little_endian_u32(data, 5)
    local rec_len_body = little_endian_u32(data, 9)
    if rec_len_body > BAICHUAN_MAX_FRAME_BYTES then
        return nil, "frame_too_large"
    end

    local full_mess_id = little_endian_u32(data, 13)
    local message_class = string.sub(data, 19, 20)
    local len_header
    local payload_offset = 0

    if message_class == hex_to_bytes("1466") then
        len_header = 20
    elseif message_class == hex_to_bytes("1464") or message_class == hex_to_bytes("0000") then
        len_header = 24
        if total < 24 then
            return nil, "need_more"
        end
        payload_offset = little_endian_u32(data, 21)
    elseif message_class == hex_to_bytes("1465") then
        len_header = 20
    else
        return nil, "bad_class"
    end

    local len_body = total - len_header
    if len_body < rec_len_body then
        return nil, "need_more"
    end

    local len_chunk = rec_len_body + len_header
    if len_chunk > BAICHUAN_MAX_FRAME_BYTES then
        return nil, "frame_too_large"
    end

    if payload_offset == 0 then
        payload_offset = rec_len_body
    end

    local len_message = payload_offset + len_header
    local data_chunk = string.sub(data, 1, len_message)
    local payload = string.sub(data, len_message + 1, len_chunk)
    local remainder = string.sub(data, len_chunk + 1)

    local ch_id = string.byte(data_chunk, 13) or 0
    local enc_body = string.sub(data_chunk, len_header + 1)
    local body = ""
    if #enc_body > 0 then
        body = baichuan_decrypt(enc_body, ch_id)
    end

    return {
        cmd_id = cmd_id,
        full_mess_id = full_mess_id,
        ch_id = ch_id,
        body = body,
        payload = payload,
        remainder = remainder,
    }, nil
end

local function baichuan_handle_data(strData)
    RUNTIME.baichuan.buffer = (RUNTIME.baichuan.buffer or "") .. (strData or "")
    if #RUNTIME.baichuan.buffer > BAICHUAN_MAX_FRAME_BYTES then
        warn("Baichuan receive buffer exceeded limit; clearing buffered data")
        RUNTIME.baichuan.buffer = ""
        return
    end

    while RUNTIME.baichuan.buffer and #RUNTIME.baichuan.buffer > 0 do
        local buffer = RUNTIME.baichuan.buffer
        if #buffer < 4 then
            return
        end

        local magic = string.sub(buffer, 1, 4)
        if magic ~= hex_to_bytes(BAICHUAN_HEADER_MAGIC) then
            warn("Baichuan invalid header: " .. bytes_to_hex(buffer, 16))
            RUNTIME.baichuan.buffer = ""
            return
        end

        local parsed, err = baichuan_process_chunk(buffer)
        if not parsed then
            if err == "need_more" then
                return
            end
            warn("Baichuan parse error: " .. tostring(err))
            RUNTIME.baichuan.buffer = ""
            return
        end

        RUNTIME.baichuan.buffer = parsed.remainder or ""

        local cmd_pending = RUNTIME.baichuan.pending[parsed.cmd_id]
        local pending = cmd_pending and cmd_pending[parsed.full_mess_id]
        if pending then
            cmd_pending[parsed.full_mess_id] = nil
            if not next(cmd_pending) then
                RUNTIME.baichuan.pending[parsed.cmd_id] = nil
            end
            dbg(
                "Baichuan response cmd_id="
                    .. tostring(parsed.cmd_id)
                    .. " mess_id="
                    .. tostring(parsed.full_mess_id)
                    .. " body_prefix="
                    .. tostring(string.sub(parsed.body or "", 1, 48))
            )
            pending.callback(parsed)
        else
            baichuan_handle_unsolicited(parsed.cmd_id, parsed.full_mess_id, parsed.body or "", parsed.payload or "")
        end
    end
end

local function post_json(url, body, callback)
    local headers = {
        ["Content-Type"] = "application/json",
    }

    dbg("HTTP POST " .. url)
    C4:urlPost(url, body, headers, false, function(ticketId, responseData, responseCode, tHeaders)
        callback(ticketId, responseData, responseCode, tHeaders)
    end)
end

local function fire_event(name)
    info("Firing event: " .. name)
    C4:FireEvent(name)
end

local function fire_visitor_pressed(source)
    local elapsed_ms = now_ms() - (RUNTIME.last_visitor_event_ms or 0)
    local debounce_ms = (tonumber(RUNTIME.config.debounce_seconds) or 3) * 1000
    if elapsed_ms < debounce_ms then
        dbg("Ignoring visitor event during debounce window from " .. tostring(source))
        return
    end

    RUNTIME.last_visitor_event_ms = now_ms()
    update_property(PROPERTY_LAST_VISITOR_EVENT, now_string())
    set_variable(VARIABLE_LAST_VISITOR_EVENT, now_string())
    fire_event("Visitor Pressed")
end

local function mark_connection_status(status)
    local was_connected = RUNTIME.connected
    RUNTIME.connected = (status == "ONLINE")

    if RUNTIME.connected then
        update_property(PROPERTY_CONNECTION_STATUS, "Connected")
        set_variable(VARIABLE_CONNECTION_STATUS, "Connected")
        if RUNTIME.connection_lost_fired then
            info("Connection restored")
            RUNTIME.connection_lost_fired = false
        end
    else
        update_property(PROPERTY_CONNECTION_STATUS, "Disconnected")
        set_variable(VARIABLE_CONNECTION_STATUS, "Disconnected")
        if was_connected and not RUNTIME.connection_lost_fired and not RUNTIME.shutting_down then
            warn("Connection lost")
            RUNTIME.connection_lost_fired = true
        end
    end
end

local function handle_pending_refresh()
    if RUNTIME.pending_refresh_reason then
        local reason = RUNTIME.pending_refresh_reason
        RUNTIME.pending_refresh_reason = nil
        REOLINK.RefreshVisitorState(reason)
    end
end

local function build_login_body()
    return string.format(
        '[{"cmd":"Login","action":0,"param":{"User":{"userName":"%s","password":"%s"}}}]',
        json_escape(RUNTIME.config.username),
        json_escape(RUNTIME.config.password)
    )
end

local function build_getevents_body(channel)
    return string.format(
        '[{"cmd":"GetEvents","action":0,"param":{"channel":%d}}]',
        tonumber(channel) or 0
    )
end

set_refresh_result = function(message)
    update_property(PROPERTY_LAST_REFRESH_RESULT, message)
end

local function evaluate_events_response(decoded, reason)
    if type(decoded) ~= "table" or type(decoded[1]) ~= "table" then
        set_refresh_result("Invalid GetEvents response")
        return
    end

    local item = decoded[1]
    if tonumber(item.code) ~= 0 then
        set_refresh_result("GetEvents failed code " .. tostring(item.code))
        return
    end

    local value = item.value or {}
    local visitor = value.visitor or {}
    local supported = tonumber(visitor.support or 0) == 1
    local active = supported and tonumber(visitor.alarm_state or 0) == 1
    local previous = RUNTIME.visitor_state

    RUNTIME.visitor_state = active
    set_refresh_result("visitor=" .. tostring(active) .. " source=" .. tostring(reason))

    dbg("GetEvents visitor support=" .. tostring(supported) .. " active=" .. tostring(active) .. " previous=" .. tostring(previous))

    if active and previous ~= true then
        fire_visitor_pressed(reason)
    elseif not active and previous == true then
        dbg("Visitor state reset to false from source " .. tostring(reason))
    end
end

local function perform_login()
    if RUNTIME.login_in_flight then
        return
    end

    RUNTIME.login_in_flight = true
    start_http_watchdog("login_watchdog_timer", "login_in_flight", "Login")
    set_refresh_result("Logging in at " .. now_string())

    local url = base_url() .. "?cmd=Login&token=null"
    local body = build_login_body()
    post_json(url, body, function(ticketId, responseData, responseCode, tHeaders)
        RUNTIME.login_in_flight = false
        clear_http_watchdog("login_watchdog_timer")

        if tonumber(responseCode) ~= 200 then
            set_refresh_result("Login failed HTTP " .. tostring(responseCode))
            warn("Reolink login failed with HTTP " .. tostring(responseCode))
            return
        end

        if not responseData or responseData == "" then
            set_refresh_result("Login empty response")
            warn("Reolink login returned empty response")
            return
        end

        local decoded, err = parse_json(responseData)
        if not decoded then
            set_refresh_result("Login JSON error")
            warn("Reolink login JSON decode failed: " .. tostring(err))
            return
        end

        local item = decoded[1]
        if type(item) ~= "table" or tonumber(item.code) ~= 0 then
            set_refresh_result("Login failed API code")
            warn("Reolink login returned unexpected payload")
            return
        end

        local token = item.value and item.value.Token and item.value.Token.name
        local lease_time = item.value and item.value.Token and tonumber(item.value.Token.leaseTime)
        if not token or not lease_time then
            set_refresh_result("Login missing token")
            warn("Reolink login response missing token data")
            return
        end

        RUNTIME.token = tostring(token)
        RUNTIME.token_expiry_ms = now_ms() + (lease_time * 1000)
        set_refresh_result("Login OK at " .. now_string())
        dbg("Reolink login succeeded, leaseTime=" .. tostring(lease_time))
        handle_pending_refresh()
    end)
end

local function perform_getevents(reason)
    if RUNTIME.refresh_in_flight then
        RUNTIME.pending_refresh_reason = reason or "queued_refresh"
        return
    end

    RUNTIME.refresh_in_flight = true
    start_http_watchdog("refresh_watchdog_timer", "refresh_in_flight", "GetEvents")
    local url = base_url() .. "?cmd=GetEvents&token=" .. tostring(RUNTIME.token)
    local body = build_getevents_body(RUNTIME.config.channel)

    post_json(url, body, function(ticketId, responseData, responseCode, tHeaders)
        RUNTIME.refresh_in_flight = false
        clear_http_watchdog("refresh_watchdog_timer")

        if tonumber(responseCode) ~= 200 then
            set_refresh_result("GetEvents HTTP " .. tostring(responseCode))
            warn("GetEvents failed with HTTP " .. tostring(responseCode))
            if tonumber(responseCode) == 401 then
                RUNTIME.token = nil
                RUNTIME.token_expiry_ms = 0
            end
            handle_pending_refresh()
            return
        end

        if not responseData or responseData == "" then
            set_refresh_result("GetEvents empty response")
            warn("GetEvents returned empty response")
            handle_pending_refresh()
            return
        end

        local decoded, err = parse_json(responseData)
        if not decoded then
            set_refresh_result("GetEvents JSON error")
            warn("GetEvents JSON decode failed: " .. tostring(err))
            handle_pending_refresh()
            return
        end

        evaluate_events_response(decoded, reason or "refresh")
        handle_pending_refresh()
    end)
end

start_poll_timer = function()
    cancel_timer("poll_timer")
    local interval_seconds = tonumber(RUNTIME.config.poll_fallback_seconds) or 5
    local interval_ms = math.max(interval_seconds, 1) * 1000
    RUNTIME.poll_timer = C4:SetTimer(interval_ms, function()
        REOLINK.RefreshVisitorState("poll")
    end, true)
end

schedule_state_refresh = function(reason)
    cancel_timer("state_refresh_timer")
    local delay_ms = tonumber(RUNTIME.config.push_settling_delay_ms) or 250
    RUNTIME.state_refresh_timer = C4:SetTimer(delay_ms, function()
        set_refresh_result("Pending refresh from " .. tostring(reason))
        dbg("State refresh requested after " .. tostring(reason))
        REOLINK.RefreshVisitorState(reason)
    end, false)
end

function REOLINK.CloseConnection()
    cancel_timer("state_refresh_timer")
    cancel_timer("reconnect_timer")
    stop_poll_timer()
    reset_http_session()
    baichuan_clear_session()
    if RUNTIME.connected then
        dbg("Closing Baichuan TCP connection")
    end
    C4:NetDisconnect(DEFAULT_NETBINDING, RUNTIME.config.baichuan_port)
    mark_connection_status("OFFLINE")
end

function REOLINK.OpenConnection()
    refresh_config()
    if not has_minimum_config() then
        update_property(PROPERTY_CONNECTION_STATUS, "Missing config")
        set_variable(VARIABLE_CONNECTION_STATUS, "Missing config")
        warn("Doorbell IP, Username, and Password are required before connecting")
        return
    end

    start_poll_timer()
    cancel_timer("reconnect_timer")

    -- Baichuan push on port 9000 is a raw TCP transport. The HTTPS property is
    -- reserved for the local Reolink API refresh work that will be added next.
    dbg("Creating standard TCP network binding to " .. RUNTIME.config.host)
    C4:CreateNetworkConnection(DEFAULT_NETBINDING, RUNTIME.config.host)

    OCS[DEFAULT_NETBINDING] = function(idBinding, nPort, strStatus)
        dbg("Connection status changed: binding=" .. tostring(idBinding) .. " port=" .. tostring(nPort) .. " status=" .. tostring(strStatus))
        if nPort == RUNTIME.config.baichuan_port then
            mark_connection_status(strStatus)
            if strStatus == "ONLINE" then
                cancel_timer("reconnect_timer")
                baichuan_request_nonce()
            else
                baichuan_clear_session()
                start_poll_timer()
                schedule_reconnect()
            end
        end
    end

    RFN[DEFAULT_NETBINDING] = function(idBinding, nPort, strData)
        if idBinding ~= DEFAULT_NETBINDING or nPort ~= RUNTIME.config.baichuan_port then
            return
        end

        local byte_count = strData and #strData or 0
        dbg("Received Baichuan data bytes=" .. tostring(byte_count))
        RUNTIME.last_push_ms = now_ms()
        update_property(PROPERTY_LAST_PUSH_TIMESTAMP, now_string())
        set_variable(VARIABLE_LAST_PUSH_TIMESTAMP, now_string())
        baichuan_handle_data(strData or "")
    end

    update_property(PROPERTY_CONNECTION_STATUS, "Connecting")
    dbg("Opening Baichuan TCP connection to " .. RUNTIME.config.baichuan_port)
    C4:NetConnect(DEFAULT_NETBINDING, RUNTIME.config.baichuan_port, "TCP")
end

function REOLINK.ReconnectNow()
    info("Reconnect requested")
    REOLINK.CloseConnection()
    REOLINK.OpenConnection()
end

function REOLINK.RefreshVisitorState(reason)
    refresh_config()
    reason = reason or "manual"
    set_refresh_result("Refresh requested from " .. tostring(reason) .. " at " .. now_string())
    dbg("Visitor state refresh requested from " .. tostring(reason))

    if not has_minimum_config() then
        set_refresh_result("Missing config")
        return
    end

    if token_is_valid() then
        perform_getevents(reason)
    else
        RUNTIME.pending_refresh_reason = reason
        perform_login()
    end
end

function REOLINK.TestVisitorEvent()
    fire_visitor_pressed("manual_test")
end

function OnDriverInit()
    ensure_runtime_defaults()
end

function OnDriverLateInit()
    ensure_runtime_defaults()
    ensure_programming_variables()
    refresh_config()
    RUNTIME.initializing_properties = true
    RUNTIME.shutting_down = false
    update_property(PROPERTY_CONNECTION_STATUS, "Disconnected")
    update_property(PROPERTY_LAST_REFRESH_RESULT, "Scaffold loaded")
    set_variable(VARIABLE_CONNECTION_STATUS, "Disconnected")
    set_variable(VARIABLE_LAST_PUSH_TIMESTAMP, "Never")
    set_variable(VARIABLE_LAST_VISITOR_EVENT, "Never")

    if C4.AllowExecute then
        C4:AllowExecute(true)
    end

    if C4.urlSetTimeout then
        C4:urlSetTimeout(10)
    end

    for property, _ in pairs(Properties) do
        OnPropertyChanged(property)
    end

    RUNTIME.initializing_properties = false

    REOLINK.OpenConnection()
end

function OnDriverDestroyed()
    RUNTIME.shutting_down = true
    cancel_timer("state_refresh_timer")
    stop_poll_timer()
    cancel_timer("reconnect_timer")
    clear_http_watchdog("login_watchdog_timer")
    clear_http_watchdog("refresh_watchdog_timer")
    REOLINK.CloseConnection()
end

function OnPropertyChanged(strProperty)
    local value = Properties[strProperty]
    if value == nil then
        value = ""
    end

    local key = sanitize_property_name(strProperty)
    local handler = OPC[key]
    if handler and type(handler) == "function" then
        local success, ret = pcall(handler, value)
        if not success then
            warn("OnPropertyChanged error for " .. tostring(strProperty) .. ": " .. tostring(ret))
        end
    end
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
    local handler = OCS[idBinding]
    if handler and type(handler) == "function" then
        local success, ret = pcall(handler, idBinding, nPort, strStatus)
        if not success then
            warn("OnConnectionStatusChanged error: " .. tostring(ret))
        end
    end
end

function ReceivedFromNetwork(idBinding, nPort, strData)
    local handler = RFN[idBinding]
    if handler and type(handler) == "function" then
        local success, ret = pcall(handler, idBinding, nPort, strData)
        if not success then
            warn("ReceivedFromNetwork error: " .. tostring(ret))
        end
    end
end

function ExecuteCommand(strCommand, tParams)
    dbg("ExecuteCommand called: " .. tostring(strCommand))

    if strCommand == "LUA_ACTION" and tParams and tParams.ACTION then
        strCommand = tParams.ACTION
    end

    if strCommand == "RECONNECT_NOW" then
        REOLINK.ReconnectNow()
    elseif strCommand == "TEST_VISITOR_EVENT" then
        REOLINK.TestVisitorEvent()
    elseif strCommand == "REFRESH_VISITOR_STATE" then
        REOLINK.RefreshVisitorState()
    end
end

function OPC.Debug_Mode(value)
    dbg("Debug Mode set to " .. tostring(value))
end

function OPC.Doorbell_IP(value)
    RUNTIME.config.host = value
    reset_http_session()
    if not RUNTIME.initializing_properties then
        REOLINK.ReconnectNow()
    end
end

function OPC.API_Port(value)
    RUNTIME.config.api_port = tonumber(value) or 443
    reset_http_session()
    if not RUNTIME.initializing_properties then
        REOLINK.RefreshVisitorState("api_port_changed")
    end
end

function OPC.Use_HTTPS(value)
    RUNTIME.config.use_https = (value == "Yes")
    reset_http_session()
    if not RUNTIME.initializing_properties then
        REOLINK.RefreshVisitorState("http_mode_changed")
    end
end

function OPC.Baichuan_Port(value)
    RUNTIME.config.baichuan_port = tonumber(value) or 9000
    reset_http_session()
    if not RUNTIME.initializing_properties then
        REOLINK.ReconnectNow()
    end
end

function OPC.Username(value)
    RUNTIME.config.username = value
    reset_http_session()
    if not RUNTIME.initializing_properties then
        REOLINK.ReconnectNow()
    end
end

function OPC.Password(value)
    RUNTIME.config.password = value
    reset_http_session()
    if not RUNTIME.initializing_properties then
        REOLINK.ReconnectNow()
    end
end

function OPC.Channel(value)
    RUNTIME.config.channel = tonumber(value) or 0
    reset_http_session()
    if not RUNTIME.initializing_properties then
        REOLINK.RefreshVisitorState("channel_changed")
    end
end

function OPC.Debounce_Seconds(value)
    RUNTIME.config.debounce_seconds = tonumber(value) or 3
end

function OPC.Push_Settling_Delay_MS(value)
    RUNTIME.config.push_settling_delay_ms = tonumber(value) or 250
end

function OPC.Poll_Fallback_Seconds(value)
    RUNTIME.config.poll_fallback_seconds = tonumber(value) or 5
    if not RUNTIME.initializing_properties and (not RUNTIME.connected or not RUNTIME.baichuan.subscribed) then
        restart_poll_timer_if_running()
    end
end
