local tests = {}

local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "assert_equal failed") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function assert_true(value, message)
    if not value then
        error(message or "assert_true failed", 2)
    end
end

local function default_properties()
    return {
        ["Debug Mode"] = "Off",
        ["Doorbell IP"] = "192.0.2.10",
        ["API Port"] = "443",
        ["Use HTTPS"] = "Yes",
        ["Baichuan Port"] = "9000",
        ["Username"] = "admin",
        ["Password"] = "password",
        ["Channel"] = "0",
        ["Debounce Seconds"] = "3",
        ["Push Settling Delay MS"] = "250",
        ["Poll Fallback Seconds"] = "5",
        ["Connection Status"] = "Disconnected",
        ["Last Push Timestamp"] = "Never",
        ["Last Visitor Event"] = "Never",
        ["Last Refresh Result"] = "Not started",
    }
end

local function new_harness()
    OPC = {}
    EC = {}
    OCS = {}
    RFN = {}
    RUNTIME = {}
    REOLINK = {}
    Properties = default_properties()
    Variables = {}
    bit32 = {
        bxor = function(a, b, c)
            return (a ~ b) ~ (c or 0)
        end,
    }
    bit = nil

    local harness = {
        time_ms = 1000000,
        timers = {},
        requests = {},
        events = {},
        properties = {},
        variables = {},
        network_sends = {},
    }

    C4 = {}

    function C4:GetTime()
        return harness.time_ms
    end

    function C4:UpdateProperty(name, value)
        harness.properties[name] = tostring(value)
        Properties[name] = tostring(value)
    end

    function C4:AddVariable(name, value)
        Variables[name] = tostring(value)
        harness.variables[name] = tostring(value)
    end

    function C4:SetVariable(name, value)
        Variables[name] = tostring(value)
        harness.variables[name] = tostring(value)
    end

    function C4:FireEvent(name)
        table.insert(harness.events, name)
    end

    function C4:SetTimer(ms, callback, repeating)
        local timer = {
            ms = ms,
            callback = callback,
            repeating = repeating,
            cancelled = false,
        }

        function timer:Cancel()
            self.cancelled = true
        end

        table.insert(harness.timers, timer)
        return timer
    end

    function C4:urlPost(url, body, headers, secure, callback)
        local request = {
            url = url,
            body = body,
            headers = headers,
            secure = secure,
            callback = callback,
        }
        table.insert(harness.requests, request)

        if harness.auto_http then
            local response = harness.auto_http(url, body, #harness.requests)
            if response then
                callback(#harness.requests, response.body, response.code or 200, response.headers or {})
            end
        end
    end

    function C4:JsonDecode(raw)
        if raw == "LOGIN_OK" then
            return {
                {
                    code = 0,
                    value = {
                        Token = {
                            name = "token-from-login",
                            leaseTime = 3600,
                        },
                    },
                },
            }
        end

        if raw == "EVENT_ACTIVE" then
            return {
                {
                    code = 0,
                    value = {
                        visitor = {
                            support = 1,
                            alarm_state = 1,
                        },
                    },
                },
            }
        end

        if raw == "EVENT_INACTIVE" then
            return {
                {
                    code = 0,
                    value = {
                        visitor = {
                            support = 1,
                            alarm_state = 0,
                        },
                    },
                },
            }
        end

        error("Unexpected JSON fixture: " .. tostring(raw))
    end

    function C4:Hash()
        return "0123456789ABCDEF0123456789ABCDEF"
    end

    function C4:SendToNetwork(binding, port, packet)
        table.insert(harness.network_sends, {
            binding = binding,
            port = port,
            packet = packet,
        })
    end

    function C4:CreateNetworkConnection(binding, host)
        harness.network_connection = {
            binding = binding,
            host = host,
        }
    end

    function C4:NetConnect(binding, port, protocol)
        harness.net_connect = {
            binding = binding,
            port = port,
            protocol = protocol,
        }
    end

    function C4:NetDisconnect(binding, port)
        harness.net_disconnect = {
            binding = binding,
            port = port,
        }
    end

    function C4:AllowExecute(value)
        harness.allow_execute = value
    end

    function C4:urlSetTimeout(value)
        harness.url_timeout = value
    end

    function harness:load_driver()
        dofile("driver.lua")
        OnDriverInit()
    end

    function harness:complete_request(index, body, code)
        local request = assert(self.requests[index], "missing request " .. tostring(index))
        request.callback(index, body, code or 200, {})
    end

    function harness:complete_pending(cmd_id, response)
        local by_message = RUNTIME.baichuan.pending[cmd_id]
        assert_true(by_message, "missing pending command " .. tostring(cmd_id))

        local full_mess_id, pending = next(by_message)
        assert_true(pending, "missing pending callback for command " .. tostring(cmd_id))
        by_message[full_mess_id] = nil
        if not next(by_message) then
            RUNTIME.baichuan.pending[cmd_id] = nil
        end

        pending.callback(response or {})
    end

    return harness
end

function tests.push_refresh_fires_even_when_cached_visitor_state_is_true()
    local h = new_harness()
    h.auto_http = function(url)
        assert_true(string.find(url, "cmd=GetEvents", 1, true), "expected GetEvents request")
        return { body = "EVENT_ACTIVE" }
    end
    h:load_driver()

    RUNTIME.visitor_state = true
    RUNTIME.token = "warm-token"
    RUNTIME.token_expiry_ms = h.time_ms + 3600000
    RUNTIME.last_visitor_event_ms = h.time_ms - 10000

    REOLINK.RefreshVisitorState("baichuan_push_33_burst1")
    assert_equal(#h.events, 1, "push refresh should fire despite cached true state")
    assert_equal(h.events[1], "Visitor Pressed", "unexpected event")

    REOLINK.RefreshVisitorState("baichuan_push_33_burst2")
    assert_equal(#h.events, 1, "debounce should suppress burst duplicates")
end

function tests.expired_token_logs_in_then_prioritizes_pending_push_refresh()
    local h = new_harness()
    h.auto_http = function(url)
        if string.find(url, "cmd=Login", 1, true) then
            return { body = "LOGIN_OK" }
        end

        assert_true(string.find(url, "cmd=GetEvents", 1, true), "expected GetEvents after login")
        return { body = "EVENT_ACTIVE" }
    end
    h:load_driver()

    RUNTIME.last_visitor_event_ms = h.time_ms - 10000

    REOLINK.RefreshVisitorState("baichuan_push_33_burst1")

    assert_equal(#h.requests, 2, "login should be followed by pending push refresh")
    assert_true(string.find(h.requests[1].url, "cmd=Login", 1, true), "first request should login")
    assert_true(string.find(h.requests[2].url, "cmd=GetEvents", 1, true), "second request should refresh events")
    assert_equal(#h.events, 1, "push should fire after login")
    assert_equal(RUNTIME.token, "token-from-login", "token should be stored")
    assert_true(RUNTIME.token_renewal_timer ~= nil, "token renewal timer should be scheduled")
    assert_equal(RUNTIME.token_renewal_timer.ms, 3540000, "token renewal should happen one minute before expiry")
end

function tests.push_refresh_uses_separate_lane_while_poll_refresh_is_in_flight()
    local h = new_harness()
    h:load_driver()

    RUNTIME.token = "warm-token"
    RUNTIME.token_expiry_ms = h.time_ms + 3600000
    RUNTIME.last_visitor_event_ms = h.time_ms - 10000

    REOLINK.RefreshVisitorState("poll")
    assert_equal(#h.requests, 1, "poll should start one request")
    assert_true(RUNTIME.refresh_in_flight, "poll refresh should be in flight")

    REOLINK.RefreshVisitorState("baichuan_push_33_burst1")
    assert_equal(#h.requests, 2, "push should not wait behind poll refresh")
    assert_true(RUNTIME.push_refresh_in_flight, "push refresh should have its own in-flight state")

    h:complete_request(2, "EVENT_ACTIVE")
    assert_equal(#h.events, 1, "push response should fire visitor event")
    assert_true(RUNTIME.refresh_in_flight, "poll refresh should still be independently in flight")
    assert_true(not RUNTIME.push_refresh_in_flight, "push refresh should complete independently")
end

function tests.connection_status_distinguishes_tcp_from_push_subscription()
    local h = new_harness()
    h:load_driver()

    REOLINK.OpenConnection()
    assert_equal(h.properties["Connection Status"], "Connecting", "open should show connecting")

    OnConnectionStatusChanged(6001, 9000, "ONLINE")
    assert_equal(h.properties["Connection Status"], "TCP Connected - Authenticating", "online TCP should start auth stage")

    h:complete_pending(1, { body = "<body><nonce>abc123</nonce></body>" })
    assert_equal(h.properties["Connection Status"], "TCP Connected - Logging In", "nonce should advance to login stage")

    h:complete_pending(1, {})
    assert_equal(h.properties["Connection Status"], "TCP Connected - Subscribing", "login should advance to subscribe stage")

    h:complete_pending(31, {})
    assert_equal(h.properties["Connection Status"], "Push Subscribed", "subscribe ack should show push readiness")
    assert_true(RUNTIME.baichuan.subscribed, "driver should mark Baichuan subscribed")
    assert_true(RUNTIME.poll_timer == nil, "poll fallback should stop after push subscription")
end

local names = {}
for name, _ in pairs(tests) do
    table.insert(names, name)
end
table.sort(names)

local passed = 0
for _, name in ipairs(names) do
    local ok, err = pcall(tests[name])
    if not ok then
        io.stderr:write("FAIL ", name, "\n", tostring(err), "\n")
        os.exit(1)
    end
    print("PASS " .. name)
    passed = passed + 1
end

print(string.format("%d behavioral tests passed", passed))
