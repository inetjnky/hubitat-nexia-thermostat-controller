definition(
    name: "Nexia Thermostat Controller",
    namespace: "jason",
    author: "inetjnky",
    description: "Thermostat OFF when a contact sensor stays open (2 min); outdoor-temp rules (HEAT at/below 45, COOL at/above 55, OFF+fan cycle between) with selectable primary/backup temp sources + auto failover and Pushover alerts (customizable text). Watchdogs re-assert mode/setpoints/fan. Maintenance pause (via required pause switch) sends thermostat OFF + fan auto, verifies the device confirms, then engages hands-off; rules re-apply on resume or sensor-clear, delaying COOL by the configured minutes (a brief sensor blip during the wait re-arms it).",
    category: "Convenience",
    iconUrl: "",
    iconX2Url: "",
    menu: "Automations"
)

preferences {
    page(name: "mainPage")
}

def mainPage() {
    dynamicPage(name: "mainPage", title: "", install: true, uninstall: true) {
        section("Thermostat(s) to control") {
            input "thermostats", "capability.thermostat",
                title: "Nexia thermostat(s)", multiple: true, required: true, submitOnChange: true
        }
        section("Maintenance pause / resume") {
            paragraph "Current status: ${isPaused() ? '⏸ PAUSED (wall thermostat has control)' : '▶ ACTIVE (automation in control)'}"
            input "pauseSwitch", "capability.switch",
                title: "Pause switch (REQUIRED — select a Virtual Switch device, e.g. 'Thermostat Guard Pause')",
                required: true, multiple: false, submitOnChange: true
            input "btnAction", "enum",
                title: "Action — choose an option to execute (acts like a button)",
                options: ["pause": "⏸ PAUSE — thermostat OFF, verified, then hands-off",
                          "resume": "▶ RESUME — automation re-takes control (COOL delayed)",
                          "test": "🔔 TEST — send your configured Pause message now"],
                required: false, submitOnChange: true
            input "coolDelayMinutes", "number",
                title: "Minutes to delay COOL mode on resume or after all sensors close (thermostat stays off during the delay)",
                defaultValue: 5, range: "1..120", required: true
            paragraph "PAUSE sends mode off + fan auto, verifies the thermostat actually reports OFF (up to 3 re-sends), then engages hands-off — the in-app Action flips the pause switch ON only after that verification; flipping the switch from a dashboard runs the same apply-then-verify sequence. If OFF can't be verified, the pause still engages and you get a Pushover alert. RESUME turns the switch OFF and re-applies the outdoor-temp rules immediately — except COOL, which waits the minutes configured above while the thermostat stays off. While the switch is ON: no sensor OFF, no outdoor-temp rules, no fan duty cycle, no watchdogs. Pause state survives hub reboots."
        }
        section("Contact sensors") {
            input "contactSensors", "capability.contactSensor",
                title: "Turn thermostat OFF when any of these stays open", multiple: true,
                required: false, submitOnChange: true
            if (contactSensors) {
                input "offDelayMinutes", "number",
                    title: "Minutes a sensor must stay open before OFF (timer restarts if another opens)",
                    defaultValue: 2, range: "1..120", required: true
                paragraph "After a sensor-protection OFF, once ALL sensors close the outdoor-temp rules re-apply immediately — except COOL, which waits the delay configured in the pause/resume section (thermostat stays off during that wait). A brief open→close blip during that COOL wait re-arms the wait."
            }
        }
        section("Outdoor temperature rules (°F)") {
            paragraph "At or above the warm threshold: COOL mode at ${mildCoolSp ?: 71}<br/>" +
                "Between thresholds: OFF${fanCycle ? ' + fan duty cycle' : ''}<br/>" +
                "At or below the cold threshold: HEAT mode at ${coldHeatSp ?: 72}"
            input "mildThreshold", "number", title: "Warm threshold — COOL mode at/above this", defaultValue: 55, required: true
            input "coldThreshold", "number", title: "Cold threshold — HEAT mode at/below this", defaultValue: 45, required: true
            input "mildCoolSp", "number", title: "Cool setpoint — used at/above warm threshold (COOL mode)", defaultValue: 71, required: true
            input "coldHeatSp", "number", title: "Heat setpoint — used at/below cold threshold (HEAT mode)", defaultValue: 72, required: true
        }
        section("Outdoor temp source & failover") {
            input "primaryTempSensor", "capability.temperatureMeasurement",
                title: "PRIMARY outdoor temperature device",
                required: true, submitOnChange: true
            paragraph "Can be the Nexia thermostat itself (the app then uses its Trane-reported 'outdoorTemperature' attribute, NOT the indoor temp) or any outdoor sensor/weather device ('temperature' attribute). The log shows which attribute was bound."
            input "backupOutdoorSensor", "capability.temperatureMeasurement",
                title: "Backup outdoor temperature device (optional — used automatically if primary goes stale)",
                required: false, submitOnChange: true
            input "stalenessHours", "number",
                title: "Hours without a primary temperature update before failing over to backup",
                defaultValue: 3, range: "1..24", required: true
            paragraph "The Nexia driver only publishes outdoor temp when it CHANGES, so a long flat-temperature stretch can look stale. If you see false failovers on calm days, raise this value. Avoid selecting the same device for both primary and backup."
            input "notifyFailover", "bool",
                title: "Pushover notifications on failover / stale / recovery / pause", defaultValue: true, submitOnChange: true
            if (notifyFailover) {
                input "pushoverDevices", "capability.notification",
                    title: "Pushover device(s) (created by Pushover Manager)",
                    required: true, multiple: true
                section("Pushover message text (all optional — blank field = built-in default)") {
                    input "notifyPrefix", "text",
                        title: "Prefix before every message (clear the field to send with NO prefix)",
                        defaultValue: "Nexia Thermostat Guard", required: false
                    input "msgPause", "text",
                        title: "⏸ Pause message", required: false,
                        defaultValue: "Maintenance PAUSE engaged — thermostat turned OFF; automation is hands-off; the wall thermostat has full control"
                    input "msgPauseUnverified", "text",
                        title: "⏸ Pause-unverified message — tokens: {device}", required: false,
                        defaultValue: "PAUSE engaged but the thermostat did not confirm OFF ({device}) — if it is still running, turn it off at the wall and check the Nexia connection"
                    input "msgResume", "text",
                        title: "▶ Resume message", required: false,
                        defaultValue: "Maintenance pause released — automation resumes control"
                    input "msgFailover", "text",
                        title: "Failover message — tokens: {device} {temp} {age}", required: false,
                        defaultValue: "Primary outdoor temp stale (last update {age}) — failing over to backup {device} ({temp}°F)"
                    input "msgStale", "text",
                        title: "Stale, no-backup message — tokens: {temp} {age}", required: false,
                        defaultValue: "Primary outdoor temp stale (last update {age}), no backup available — thermostat rules frozen on last known {temp}°F"
                    input "msgRecovered", "text",
                        title: "Primary-recovered message", required: false,
                        defaultValue: "Primary outdoor temp recovered — using primary source again"
                    input "msgNoTemp", "text",
                        title: "No-temperature-available message", required: false,
                        defaultValue: "No outdoor temperature available (primary and backup) — thermostat rules paused"
                    paragraph "Tokens are replaced with live values at send time: {age} = hours since the last primary update, {device} = device name(s), {temp} = the reading used. A token with no value for that event stays as literal text — only use tokens where the title says they're supported. The app log always records the full detail no matter what these fields say. Use the 🔔 TEST action at the top of the app to preview your Pause text through the real send path."
                }
            }
        }
        section("Fan duty cycle during OFF band (outdoor between thresholds)") {
            input "fanCycle", "bool", title: "Run the fan on a duty cycle while the OFF band is active",
                defaultValue: true, submitOnChange: true
            if (fanCycle) {
                input "fanActiveMode", "enum", title: "Fan mode during the ON phase",
                    options: ["on", "circulate"], defaultValue: "on", required: true
                input "fanOnMinutes", "number", title: "Minutes fan runs per cycle",
                    defaultValue: 30, range: "1..60", required: true
                input "fanOffMinutes", "number", title: "Minutes fan rests between cycles",
                    defaultValue: 30, range: "1..60", required: true
                paragraph "ON phase = fan '${fanActiveMode ?: 'on'}'. 'on' runs continuously (exactly 30 min/hour with defaults); 'circulate' lets the thermostat duty-cycle internally (less actual runtime). OFF phase = fan 'auto'. The cycle pauses while any sensor is open and during any pending COOL delay."
            }
        }
        section("Options") {
            input "applyPermanentHold", "bool",
                title: "Send Permanent Hold after applying setpoints (stops thermostat schedule from overriding)",
                defaultValue: false
            input "applyOnSave", "bool", title: "Apply rules when this app is saved/reopened", defaultValue: true
            input "logEnable", "bool", title: "Enable debug logging", defaultValue: false
        }
    }
}

def installed() {
    if (state.forcedOffBySensor == null) state.forcedOffBySensor = false
    if (state.paused == null) state.paused = false
    if (state.pauseEngaged == null) state.pauseEngaged = false
    state.lastPrimaryTempMs = now()
    initialize()
    if (applyOnSave) evaluateNow()
}

def updated() {
    if (state.forcedOffBySensor == null) state.forcedOffBySensor = false
    if (state.paused == null) state.paused = false
    if (state.pauseEngaged == null) state.pauseEngaged = false
    if (state.lastPrimaryTempMs == null) state.lastPrimaryTempMs = now()
    unsubscribe()
    unschedule()
    initialize()
    def acted = handleActionRequest()
    if (applyOnSave && !acted) evaluateNow()
}

def initialize() {
    state.paused = isPaused()   // reconcile the display mirror from the switch
    if (contactSensors) {
        subscribe(contactSensors, "contact.open", sensorOpenHandler)
        subscribe(contactSensors, "contact.closed", sensorCloseHandler)
    }
    if (thermostats) {
        subscribe(thermostats, "thermostatMode", modeHandler)
        subscribe(thermostats, "thermostatFanMode", fanModeHandler)
        subscribe(thermostats, "heatingSetpoint", setpointHandler)
        subscribe(thermostats, "coolingSetpoint", setpointHandler)
    }
    if (primaryTempSensor) {
        subscribe(primaryTempSensor, primaryAttrName(), primaryTempHandler)
        logInfo "Primary temp source: ${primaryTempSensor.displayName} (attribute: ${primaryAttrName()})"
        if (backupOutdoorSensor && backupOutdoorSensor.id == primaryTempSensor.id) {
            logWarn "Primary and backup temp source are the same device (${primaryTempSensor.displayName}) — failover provides no redundancy"
        }
    }
    if (backupOutdoorSensor) subscribe(backupOutdoorSensor, "temperature", backupTempHandler)
    if (pauseSwitch) {
        subscribe(pauseSwitch, "switch.on", pauseAutomation)
        subscribe(pauseSwitch, "switch.off", resumeAutomation)
    }
    runEvery15Minutes("auditTempSource")

    if (isPaused()) {
        if (!state.pauseEngaged) {
            // Switch is ON but the pause sequence never completed (flipped during downtime, or restart mid-sequence)
            logInfo "Pause switch is ON but the pause sequence did not complete — applying thermostat OFF and validating now"
            pauseNow("restart reconciliation")
        } else {
            enforcePauseQuietly()
        }
    } else {
        state.pauseEngaged = false
        // Recover the COOL delay if the hub restarted mid-wait
        if (state.pendingWarmApply) {
            runIn(coolDelaySeconds(), "warmApplyCheck", [overwrite: true])
            logInfo "Hub restart during COOL delay — timer re-armed in ${coolDelayMinutes()} min"
        }
        // Recover fan duty cycle if the hub restarted mid-cycle
        if (state.fanCycleActive) {
            logInfo "Fan duty cycle was active before restart — resuming in '${state.fanPhase ?: 'on'}' phase"
            unschedule("fanOnPhase")
            unschedule("fanOffPhase")
            if (state.fanPhase == "off") {
                setFanMode("auto", "resume rest phase")
                runIn(fanRestSeconds(), "fanOnPhase", [overwrite: true])
            } else {
                enterOnPhase("resume after restart")
            }
        }
        // Recover sensor protection across a restart
        if (state.forcedOffBySensor) {
            def open = openSensors()
            if (open) {
                runIn(offDelaySeconds(), "closeoutCheck", [overwrite: true])
                logInfo "Restart with sensor(s) open (${open.join(', ')}) — OFF check re-armed in ${offDelayMinutes()} min"
            } else {
                // Sensors closed while the hub was down (close event lost) — rules re-apply right away
                state.forcedOffBySensor = false
                state.offReassertCount = 0
                state.spReassertCount = 0
                runIn(15, "resumeApplyRules", [overwrite: true])
                logInfo "Restart after sensor-protection with all sensors closed — rules re-applied in 15 s"
            }
        } else if (state.warmDelayInterrupted && !openSensors()) {
            // A blip canceled the COOL delay before the restart; sensors are closed again — re-arm the wait
            state.warmDelayInterrupted = false
            state.pendingWarmApply = true
            runIn(coolDelaySeconds(), "warmApplyCheck", [overwrite: true])
            logInfo "Restart after a blip canceled the COOL delay — timer re-armed in ${coolDelayMinutes()} min"
        }
        // Verify mode/setpoints survived the restart if a band owns them
        if (state.appliedBand && !state.forcedOffBySensor) {
            runIn(15, "reassertSetpoints", [overwrite: true])
            logInfo "Restart while '${state.appliedBand}' band owns mode/setpoints — verification check in 15 s"
        }
    }
}

// ---- maintenance pause (switch is the single source of truth) ----
def isPaused() {
    def v = pauseSwitch?.currentValue("switch")
    if (v == null) return state.paused == true
    return (v == "on")
}

// In-app actions: pause applies OFF + verifies BEFORE engaging; resume flips the switch off
def handleActionRequest() {
    def action = settings.btnAction
    if (!action) return false
    app.updateSetting("btnAction", [value: "", type: "enum"])
    if (action == "pause") return pressPause()
    if (action == "resume") return pressResume()
    if (action == "test") return pressTest()
    return false
}

def pressPause() {
    if (isPaused()) {
        logDebug "PAUSE requested but already paused (switch is on)"
        return false
    }
    logInfo "PAUSE requested from app page — thermostat OFF first; the pause switch flips ON only after the thermostat confirms OFF"
    pauseNow("app page")
    return true
}

def pressResume() {
    if (!isPaused()) {
        logDebug "RESUME requested but not paused (switch is off)"
        return false
    }
    logInfo "RESUME requested from app page — turning pause switch OFF"
    pauseSwitch.off()
    return true
}

def pressTest() {
    logInfo "TEST Pushover requested from app page"
    notifyUser(buildPushMessage("pause", [:]))
    return true
}

def pauseAutomation(evt) { pauseNow("switch") }
def resumeAutomation(evt) { resumeNow("switch") }

// Pause sequence: apply OFF + fan auto to the device, verify, then engage hands-off.
// Runs on every trigger (app Action, dashboard switch, device page, restart reconciliation).
def pauseNow(String source) {
    if (state.pauseEngaged) { logDebug "Pause already engaged (${source}) — nothing to do"; return }
    logInfo "MAINTENANCE PAUSE requested (${source}) — sending thermostat OFF + fan auto; hands-off engages once the device confirms"
    enforcePauseQuietly()
    // Apply to the device UNCONDITIONALLY — never trust the attribute mirror on this path
    thermostats.each { t ->
        t.setThermostatMode("off")
        logInfo "${t.displayName}: mode -> off (pause command sent)"
    }
    forceFanMode("auto", "pause — system off")
    state.pauseValidCount = 0
    runIn(5, "pauseValidateCheck", [overwrite: true])
}

def pauseValidateCheck() {
    if (state.pauseEngaged) return
    def badMode = thermostats.findAll { it.currentValue("thermostatMode") != "off" }
    def badFan = thermostats.findAll { it.currentValue("thermostatFanMode") != "auto" }
    if (!badMode && !badFan) {
        logInfo "Pause verified: thermostat mode is OFF and fan is auto — engaging hands-off"
        finishPauseEngage()
        return
    }
    if ((state.pauseValidCount ?: 0) >= 3) {
        def names = (badMode + badFan).collect { it.displayName }.unique().join(", ")
        logWarn "Thermostat did not confirm OFF after ${1 + (state.pauseValidCount ?: 0)} attempts (${names}) — engaging pause anyway; the wall thermostat has control. If the system is still running, turn it off at the wall and check the Nexia connection."
        notifyUser(buildPushMessage("pauseUnverified", [device: names]))
        finishPauseEngage()
        return
    }
    state.pauseValidCount = (state.pauseValidCount ?: 0) + 1
    def detail = []
    if (badMode) detail << "mode still '${badMode.collect { it.currentValue('thermostatMode') }.unique().join(', ')}' on ${badMode.collect { it.displayName }.join(', ')}"
    if (badFan) detail << "fan still '${badFan.collect { it.currentValue('thermostatFanMode') }.unique().join(', ')}' on ${badFan.collect { it.displayName }.join(', ')}"
    logWarn "Pause verification (attempt ${state.pauseValidCount}/3): ${detail.join('; ')} — re-sending commands"
    badMode.each { it.setThermostatMode("off") }
    badFan.each { it.setThermostatFanMode("auto") }
    runIn(5, "pauseValidateCheck", [overwrite: true])
}

def finishPauseEngage() {
    state.pauseEngaged = true
    state.paused = true
    state.pauseValidCount = 0
    enforcePauseQuietly()
    if (!isPaused()) {
        // App-page path: the switch is still off — flipping it ON now completes the engagement
        logInfo "Pause switch -> ON — automation hands off; the wall thermostat has full control"
        pauseSwitch?.on()
    } else {
        // Switch-triggered path: already on
        logInfo "Automation is hands-off; the wall thermostat has full control"
    }
    notifyUser(buildPushMessage("pause", [:]))
    // Post-write re-check: catches a write the driver accepted but the Nexia cloud silently dropped
    runIn(120, "pausePostCheck", [overwrite: true])
}

def pausePostCheck() {
    if (!state.pauseEngaged) return
    def bad = thermostats.findAll { it.currentValue("thermostatMode") != "off" }
    if (!bad) { logDebug "pausePostCheck: thermostat mode still off — pause write confirmed"; return }
    logWarn "Pause re-check: ${bad.collect { it.displayName }.join(', ')} now reports mode '${bad.collect { it.currentValue('thermostatMode') }.unique().join(', ')}' — the OFF write did not hold; re-sending once"
    bad.each { it.setThermostatMode("off") }
    runIn(15, "pausePostCheckFinal", [overwrite: true])
}

def pausePostCheckFinal() {
    if (!state.pauseEngaged) return
    def bad = thermostats.findAll { it.currentValue("thermostatMode") != "off" }
    if (bad) {
        logWarn "Thermostat is still not OFF while paused (${bad.collect { it.displayName }.unique().join(', ')}) — hands-off remains in effect and no further commands will be sent; turn it off at the wall and check the Nexia connection."
        notifyUser(buildPushMessage("pauseUnverified", [device: bad.collect { it.displayName }.unique().join(", ")]))
    } else {
        logInfo "Pause re-check passed: thermostat mode is OFF — hands-off remains"
    }
}

def resumeNow(String source) {
    if (!isPaused()) {
        logDebug "Resume requested from ${source} but not paused"
        return
    }
    state.paused = false
    state.pauseEngaged = false
    unschedule("pauseValidateCheck")
    unschedule("pausePostCheck")
    unschedule("pausePostCheckFinal")
    logInfo "MAINTENANCE PAUSE released (${source}) — automation resumes control"
    notifyUser(buildPushMessage("resume", [:]))
    resumeApplyRules()
}

// Shared re-apply path (pause resume + sensor clear): apply now, except COOL gets the delay
def resumeApplyRules() {
    state.warmDelayInterrupted = false   // any deliberate re-apply supersedes an interrupted delay
    def open = openSensors()
    if (open) {
        // Sensors opened — protection takes over instead of rules
        state.appliedBand = null
        state.spReassertCount = 0
        stopFanCycle()
        runIn(offDelaySeconds(), "closeoutCheck", [overwrite: true])
        logInfo "Sensor(s) open (${open.join(', ')}) — OFF check scheduled in ${offDelayMinutes()} min"
        return
    }
    def src = resolveSource()
    announceTransition(src)
    if (src.temp == null) {
        state.lastEvalSkipped = true
        logWarn "No outdoor temperature available from primary or backup — rules paused (15-min audit will retry)"
        return
    }
    state.lastEvalSkipped = false
    def band = bandFor(src.temp)
    logInfo "Re-applying rules: outdoor ${src.temp}°F (${src.source}) -> ${band} band"
    if (band == "warm") {
        state.pendingWarmApply = true
        runIn(coolDelaySeconds(), "warmApplyCheck", [overwrite: true])
        logInfo "COOL application delayed ${coolDelayMinutes()} min — thermostat stays off during the wait"
    } else {
        applyRules(src)
    }
}

def warmApplyCheck() {
    state.pendingWarmApply = false
    if (isPaused()) { logDebug "warmApplyCheck: paused — skip"; return }
    def open = openSensors()
    if (open) {
        logWarn "warmApplyCheck: sensor(s) open (${open.join(', ')}) — sensor protection owns the thermostat; rules not applied"
        return
    }
    logInfo "COOL delay elapsed — re-applying outdoor temperature rules"
    evaluateOutdoorRules()
}

def enforcePauseQuietly() {
    unschedule("closeoutCheck")
    unschedule("warmApplyCheck")
    unschedule("resumeApplyRules")
    unschedule("reassertOff")
    unschedule("reassertFan")
    unschedule("reassertSetpoints")
    unschedule("fanOnPhase")
    unschedule("fanOffPhase")
    state.pendingWarmApply = false
    state.warmDelayInterrupted = false
    state.forcedOffBySensor = false
    state.appliedBand = null
    state.offReassertCount = 0
    state.spReassertCount = 0
    state.fanReassertCount = 0
    // Cancel fan-cycle timers WITHOUT sending commands — the wall thermostat is in charge now
    stopFanCycle(false)
}

// ---- sensor handlers ----
def sensorOpenHandler(evt) {
    if (isPaused()) { logDebug "Paused — ignoring sensor open (${evt.displayName})"; return }
    logInfo "Sensor opened: ${evt.displayName}"
    if (state.pendingWarmApply) {
        state.pendingWarmApply = false
        unschedule("warmApplyCheck")
        state.warmDelayInterrupted = true
        logInfo "COOL delay canceled (sensor opened) — re-armed if the sensor closes before the OFF timer fires"
    }
    state.appliedBand = null
    state.spReassertCount = 0
    stopFanCycle()
    runIn(offDelaySeconds(), "closeoutCheck", [overwrite: true])
    logInfo "Thermostat will turn OFF in ${offDelayMinutes()} min if a sensor is still open"
}

def closeoutCheck() {
    if (isPaused()) { logDebug "Paused — closeoutCheck skipped"; return }
    def open = openSensors()
    if (!open) {
        logDebug "closeoutCheck: all sensors closed, skipping"
        return
    }
    logInfo "Sensor(s) still open after ${offDelayMinutes()} min (${open.join(', ')}) — enforcing OFF"
    stopFanCycle()
    state.offReassertCount = 0
    thermostats.each { t ->
        if (t.currentValue("thermostatMode") != "off") {
            t.setThermostatMode("off")
            logInfo "${t.displayName}: mode -> off (sensor protection)"
        } else {
            logDebug "${t.displayName} already off"
        }
    }
    // Sensor protection owns the thermostat state from here until all sensors close
    state.forcedOffBySensor = true
}

def sensorCloseHandler(evt) {
    if (isPaused()) { logDebug "Paused — ignoring sensor close (${evt.displayName})"; return }
    logInfo "Sensor closed: ${evt.displayName}"
    def open = openSensors()
    if (open) {
        logDebug "Still open: ${open.join(', ')} — no action"
        return
    }
    // All closed: cancel a pending OFF that hasn't fired yet
    unschedule("closeoutCheck")
    if (state.forcedOffBySensor) {
        state.forcedOffBySensor = false
        state.offReassertCount = 0
        state.spReassertCount = 0
        logInfo "All sensors closed after sensor-protection OFF — re-applying outdoor temperature rules"
        resumeApplyRules()
    } else if (state.warmDelayInterrupted) {
        // A blip canceled an in-progress COOL delay — re-arm the wait (thermostat stays off)
        state.warmDelayInterrupted = false
        logInfo "All sensors closed during a canceled COOL delay — delay re-armed for ${coolDelayMinutes()} min (thermostat stays off)"
        thermostats.each { t ->
            if (t.currentValue("thermostatMode") != "off") {
                t.setThermostatMode("off")
                logInfo "${t.displayName}: mode -> off (COOL delay wait)"
            }
        }
        state.pendingWarmApply = true
        runIn(coolDelaySeconds(), "warmApplyCheck", [overwrite: true])
    } else {
        logDebug "All sensors closed; thermostat was not forced off — nothing to resume"
    }
}

// ---- outdoor temperature: primary, backup, failover ----
def primaryTempHandler(evt) {
    state.lastPrimaryTempMs = now()   // any event proves the primary is alive (tracked even while paused)
    logInfo "Outdoor temperature (primary/${evt.name}): ${evt.value}°F"
    if (isPaused()) { logDebug "Paused — outdoor temp rules suppressed"; return }
    def open = openSensors()
    if (open) {
        logInfo "Sensor(s) open (${open.join(', ')}) — outdoor temp rules suppressed; sensor protection handles OFF if it stays open"
        return
    }
    if (state.pendingWarmApply) {
        logInfo "Within COOL delay — rules will be applied when the ${coolDelayMinutes()} min timer fires"
        return
    }
    evaluateOutdoorRules()
}

def backupTempHandler(evt) {
    logInfo "Backup outdoor temperature: ${evt.value}°F"
    if (isPaused()) { logDebug "Paused — backup temp rules suppressed"; return }
    if (state.tempSourceActive == "primary") {
        logDebug "Primary is active — backup reading noted, no action"
        return
    }
    def open = openSensors()
    if (open) {
        logInfo "Sensor(s) open — rules suppressed"
        return
    }
    if (state.pendingWarmApply) {
        logInfo "Within COOL delay — rules will be applied when the timer fires"
        return
    }
    evaluateOutdoorRules()
}

def primaryAttrName() {
    def d = primaryTempSensor
    if (d == null) return "temperature"
    try {
        if (d.hasAttribute("outdoorTemperature")) return "outdoorTemperature"
    } catch (ignored) { }
    return "temperature"
}

def resolveSource() {
    def primaryTemp = primaryValue()
    def backupTemp = backupValue()
    def fresh = (primaryTemp != null) && (state.lastPrimaryTempMs != null) &&
        ((now() - state.lastPrimaryTempMs) <= stalenessMs())
    def source
    if (primaryTemp != null && (fresh || state.lastPrimaryTempMs == null)) {
        source = "primary"
    } else if (backupTemp != null) {
        source = "backup"
    } else if (primaryTemp != null) {
        source = "primary-stale"
    } else {
        source = "none"
    }
    return [source: source, primary: primaryTemp, backup: backupTemp,
            temp: (source == "backup") ? backupTemp : primaryTemp]
}

def evaluateOutdoorRules() {
    if (!thermostats) return
    if (isPaused()) { logDebug "Paused — evaluateOutdoorRules skipped"; return }
    def src = resolveSource()
    announceTransition(src)
    if (src.temp == null) {
        state.lastEvalSkipped = true
        logWarn "No outdoor temperature available from primary or backup — rule application paused (15-min audit will retry)"
        return
    }
    state.lastEvalSkipped = false
    applyRules(src)
}

def announceTransition(Map src) {
    def prev = state.tempSourceActive
    def cur = src.source
    if (prev == cur) return
    state.tempSourceActive = cur
    def ageH = primaryAgeHours()
    switch (cur) {
        case "backup":
            logWarn "Primary outdoor temp stale (last update ${ageH}) — failing over to backup ${backupOutdoorSensor?.displayName} (${src.backup}°F)"
            notifyUser(buildPushMessage("failover", [device: backupOutdoorSensor?.displayName, temp: src.backup, age: ageH]))
            break
        case "primary-stale":
            logWarn "Primary outdoor temp stale (last update ${ageH}), no backup available — rules frozen on last known ${src.primary}°F"
            notifyUser(buildPushMessage("stale", [temp: src.primary, age: ageH]))
            break
        case "primary":
            if (prev != null) {
                logInfo "Primary outdoor temp recovered — resuming primary source"
                notifyUser(buildPushMessage("recovered", [:]))
            }
            break
        case "none":
            logWarn "No outdoor temperature available from primary or backup — rules paused"
            notifyUser(buildPushMessage("notemp", [:]))
            break
    }
}

def primaryAgeHours() {
    if (state.lastPrimaryTempMs == null) return "unknown"
    return "${String.format('%.1f', (now() - state.lastPrimaryTempMs) / 3600000.0d)} h"
}

def auditTempSource() {
    if (isPaused()) { logDebug "audit: paused — skip"; return }
    def open = openSensors()
    if (open) { logDebug "audit: sensor(s) open — skip"; return }
    if (state.pendingWarmApply) { logDebug "audit: COOL delay pending — skip"; return }
    def src = resolveSource()
    if (src.source != (state.tempSourceActive ?: "none") || state.lastEvalSkipped) {
        logInfo "Outdoor temp audit: source '${state.tempSourceActive ?: 'none'}' -> '${src.source}' — re-evaluating"
        evaluateOutdoorRules()
    } else {
        logDebug "audit: temp source stable (${src.source})"
    }
}

def primaryValue() {
    if (!primaryTempSensor) return null
    return num(primaryTempSensor.currentValue(primaryAttrName()))
}

def backupValue() {
    if (!backupOutdoorSensor) return null
    return num(backupOutdoorSensor.currentValue("temperature"))
}

// ---- pushover text: templates, tokens, prefix ----
def cfgText(String name, String fallback) {
    def v = settings[name]
    if (v == null) return fallback
    def s = v.toString().trim()
    return s ? s : fallback   // cleared field = built-in default, never an empty push
}

def renderTemplate(String text, Map bindings) {
    if (!text) return ""
    def out = text
    bindings.each { k, v ->
        if (v != null) out = out.replace("{${k}}", v.toString())
    }
    return out
}

def buildPushMessage(String type, Map bindings) {
    def text
    switch (type) {
        case "pause":
            text = cfgText("msgPause", "Maintenance PAUSE engaged — thermostat turned OFF; automation is hands-off; the wall thermostat has full control")
            break
        case "pauseUnverified":
            text = cfgText("msgPauseUnverified", "PAUSE engaged but the thermostat did not confirm OFF ({device}) — if it is still running, turn it off at the wall and check the Nexia connection")
            break
        case "resume":
            text = cfgText("msgResume", "Maintenance pause released — automation resumes control")
            break
        case "failover":
            text = cfgText("msgFailover", "Primary outdoor temp stale (last update {age}) — failing over to backup {device} ({temp}°F)")
            break
        case "stale":
            text = cfgText("msgStale", "Primary outdoor temp stale (last update {age}), no backup available — thermostat rules frozen on last known {temp}°F")
            break
        case "recovered":
            text = cfgText("msgRecovered", "Primary outdoor temp recovered — using primary source again")
            break
        case "notemp":
            text = cfgText("msgNoTemp", "No outdoor temperature available (primary and backup) — thermostat rules paused")
            break
        default:
            text = ""
    }
    return renderTemplate(text, bindings)
}

def notifyUser(String msg) {
    def prefix = settings["notifyPrefix"]
    def prefixStr = (prefix == null) ? "Nexia Thermostat Guard" : prefix.toString().trim()
    def line = prefixStr ? "${prefixStr}: ${msg}" : msg
    def devs = (pushoverDevices instanceof List) ? pushoverDevices : (pushoverDevices ? [pushoverDevices] : [])
    if (!settings.notifyFailover || !devs) {
        log.warn "${line} (no Pushover device configured)"
        return
    }
    devs.each { d ->
        try {
            d.deviceNotification(line)
            logInfo "Pushover sent to ${d.displayName}"
        } catch (e) {
            logWarn "Pushover send to ${d.displayName} failed: ${e.message ?: e}"
        }
    }
}

// ---- rule application ----
def evaluateNow() {
    if (isPaused()) { logDebug "Paused — evaluateNow skipped"; return }
    def open = openSensors()
    if (open) {
        if (state.pendingWarmApply) {
            state.pendingWarmApply = false
            unschedule("warmApplyCheck")
            state.warmDelayInterrupted = true
            logInfo "COOL delay canceled (sensor opened at save) — re-armed if the sensor closes before the OFF timer fires"
        }
        state.appliedBand = null
        state.spReassertCount = 0
        stopFanCycle()
        runIn(offDelaySeconds(), "closeoutCheck", [overwrite: true])
        logInfo "Sensor(s) open at save (${open.join(', ')}) — OFF check scheduled in ${offDelayMinutes()} min"
        return
    }
    if (state.pendingWarmApply) {
        logInfo "COOL delay in progress — rules apply in ≤${coolDelayMinutes()} min"
        return
    }
    evaluateOutdoorRules()
}

def bandFor(temp) {
    def warm = num(settings.mildThreshold) ?: 55
    def cold = num(settings.coldThreshold) ?: 45
    return (temp <= cold) ? "cold" : (temp < warm) ? "off" : "warm"
}

def applyRules(Map src) {
    if (isPaused()) { logDebug "Paused — applyRules skipped"; return }
    def outdoor = src.temp
    if (outdoor == null) {
        logWarn "No outdoor temperature available — skipping rule application"
        state.lastEvalSkipped = true
        return
    }
    state.lastEvalSkipped = false
    def band = bandFor(outdoor)
    logInfo "Outdoor ${outdoor}°F (${src.source}) -> ${band}"
    thermostats.each { t ->
        switch (band) {
            case "off":
                if (t.currentValue("thermostatMode") != "off") {
                    t.setThermostatMode("off")
                    logInfo "${t.displayName}: mode -> off"
                } else {
                    logDebug "${t.displayName}: already off"
                }
                state.appliedBand = null
                state.spReassertCount = 0
                if (settings.fanCycle) {
                    ensureFanCycle()
                } else {
                    stopFanCycle()
                    setFanMode("auto", "OFF band, fan circulation disabled")
                }
                break
            case "warm":
                stopFanCycle()
                applyCoolBand(t, num(settings.mildCoolSp) ?: 71, "warm")
                break
            case "cold":
                stopFanCycle()
                applyHeatBand(t, num(settings.coldHeatSp) ?: 72, "cold")
                break
        }
    }
}

def applyHeatBand(t, heatSp, band) {
    if (t.currentValue("thermostatMode") != "heat") {
        t.setThermostatMode("heat")
        logInfo "${t.displayName}: mode -> heat"
    }
    if (num(t.currentValue("heatingSetpoint")) != heatSp) {
        t.setHeatingSetpoint(heatSp)
        logInfo "${t.displayName}: heat setpoint -> ${heatSp}°F"
    }
    if (settings.applyPermanentHold) {
        t.setHold("Permanent Hold")
        logInfo "${t.displayName}: permanent hold requested"
    }
    // This band now owns mode + heat setpoint — watchdog expectations update
    state.appliedBand = band
    state.spReassertCount = 0
}

def applyCoolBand(t, coolSp, band) {
    if (t.currentValue("thermostatMode") != "cool") {
        t.setThermostatMode("cool")
        logInfo "${t.displayName}: mode -> cool"
    }
    if (num(t.currentValue("coolingSetpoint")) != coolSp) {
        t.setCoolingSetpoint(coolSp)
        logInfo "${t.displayName}: cool setpoint -> ${coolSp}°F"
    }
    if (settings.applyPermanentHold) {
        t.setHold("Permanent Hold")
        logInfo "${t.displayName}: permanent hold requested"
    }
    // This band now owns mode + cool setpoint — watchdog expectations update
    state.appliedBand = band
    state.spReassertCount = 0
}

// ---- watchdogs (cloud write verification) ----
def modeHandler(evt) {
    logDebug "thermostatMode event: ${evt.displayName} -> ${evt.value}"
    if (isPaused()) return
    if (state.forcedOffBySensor) {
        if (evt.value == "off") {
            state.offReassertCount = 0
            return
        }
        // Should be OFF but the attribute says otherwise (stale poll or lost write)
        logWarn "${evt.displayName}: expected OFF but mode shows '${evt.value}' — re-check in 10 s"
        runIn(10, "reassertOff", [overwrite: true])
        return
    }
    if (state.appliedBand) {
        def exp = expectedOwnership()
        if (exp && evt.value != exp.mode) {
            logWarn "${evt.displayName}: expected mode '${exp.mode}' but shows '${evt.value}' — re-check in 10 s"
            runIn(10, "reassertSetpoints", [overwrite: true])
        }
    }
}

def reassertOff() {
    if (isPaused()) return
    if (!state.forcedOffBySensor) return
    def open = openSensors()
    if (!open) { state.offReassertCount = 0; return }
    def offenders = thermostats.findAll { it.currentValue("thermostatMode") != "off" }
    if (!offenders) {
        logDebug "reassertOff: mode is off on all thermostats (transient resolved)"
        state.offReassertCount = 0
        return
    }
    if ((state.offReassertCount ?: 0) >= 3) {
        logWarn "Thermostat did not stay OFF after 3 re-send attempts (${offenders.collect { it.displayName }.join(', ')}) — check the Nexia app/driver logs; sensor protection remains active and will retry on the next event."
        return
    }
    state.offReassertCount = (state.offReassertCount ?: 0) + 1
    offenders.each { t ->
        t.setThermostatMode("off")
        logWarn "reassertOff (attempt ${state.offReassertCount}/3): ${t.displayName} -> off re-sent"
    }
    runIn(10, "reassertOff", [overwrite: true])
}

def fanModeHandler(evt) {
    logDebug "thermostatFanMode event: ${evt.displayName} -> ${evt.value}"
    if (isPaused()) return
    if (!state.fanCycleActive) return
    if (openSensors()) return
    def expected = (state.fanPhase == "off") ? "auto" : (settings.fanActiveMode ?: "on")
    if (evt.value == expected) {
        state.fanReassertCount = 0
        return
    }
    logWarn "${evt.displayName}: fan should be '${expected}' but shows '${evt.value}' — re-check in 10 s"
    runIn(10, "reassertFan", [overwrite: true])
}

def reassertFan() {
    if (isPaused()) return
    if (!state.fanCycleActive) return
    if (openSensors()) return
    def expected = (state.fanPhase == "off") ? "auto" : (settings.fanActiveMode ?: "on")
    def offenders = thermostats.findAll { it.currentValue("thermostatFanMode") != expected }
    if (!offenders) {
        logDebug "reassertFan: fan already '${expected}' (transient resolved)"
        state.fanReassertCount = 0
        return
    }
    if ((state.fanReassertCount ?: 0) >= 3) {
        logWarn "Fan did not stay '${expected}' after 3 re-send attempts (${offenders.collect { it.displayName }.join(', ')}) — duty cycle timing continues; check the Nexia app/driver logs."
        return
    }
    state.fanReassertCount = (state.fanReassertCount ?: 0) + 1
    offenders.each { t ->
        t.setThermostatFanMode(expected)
        logWarn "reassertFan (attempt ${state.fanReassertCount}/3): ${t.displayName} -> ${expected} re-sent"
    }
    runIn(10, "reassertFan", [overwrite: true])
}

def expectedOwnership() {
    if (state.appliedBand == "cold") {
        return [mode: "heat", heat: num(settings.coldHeatSp) ?: 72, cool: null]
    }
    if (state.appliedBand == "warm") {
        return [mode: "cool", heat: null, cool: num(settings.mildCoolSp) ?: 71]
    }
    return null
}

def setpointHandler(evt) {
    logDebug "${evt.name} event: ${evt.displayName} -> ${evt.value}"
    if (isPaused()) return
    if (!state.appliedBand || state.forcedOffBySensor) return
    if (openSensors()) return
    def exp = expectedOwnership()
    if (exp == null) { state.appliedBand = null; return }
    if (evt.name == "heatingSetpoint" && exp.heat != null) {
        if (num(evt.value) == exp.heat) {
            state.spReassertCount = 0
            return
        }
        logWarn "${evt.displayName}: heatingSetpoint should be ${exp.heat}°F but shows ${evt.value} — re-check in 10 s"
        runIn(10, "reassertSetpoints", [overwrite: true])
        return
    }
    if (evt.name == "coolingSetpoint" && exp.cool != null) {
        if (num(evt.value) == exp.cool) {
            state.spReassertCount = 0
            return
        }
        logWarn "${evt.displayName}: coolingSetpoint should be ${exp.cool}°F but shows ${evt.value} — re-check in 10 s"
        runIn(10, "reassertSetpoints", [overwrite: true])
    }
}

def reassertSetpoints() {
    if (isPaused()) return
    if (!state.appliedBand || state.forcedOffBySensor) return
    if (openSensors()) return
    def exp = expectedOwnership()
    if (exp == null) return
    def offenders = thermostats.findAll {
        (it.currentValue("thermostatMode") != exp.mode) ||
        (exp.heat != null && num(it.currentValue("heatingSetpoint")) != exp.heat) ||
        (exp.cool != null && num(it.currentValue("coolingSetpoint")) != exp.cool)
    }
    if (!offenders) {
        logDebug "reassertSetpoints: mode/setpoints match ${state.appliedBand} band (transient resolved)"
        state.spReassertCount = 0
        return
    }
    if ((state.spReassertCount ?: 0) >= 3) {
        logWarn "Mode/setpoints did not stick after 3 re-send attempts (${offenders.collect { it.displayName }.join(', ')}) — expected mode '${exp.mode}'${exp.heat != null ? ", heat ${exp.heat}°F" : ''}${exp.cool != null ? ", cool ${exp.cool}°F" : ''}. If the driver logs show clamping, the setpoint is outside the thermostat's reported range; otherwise check the Nexia cloud/driver logs."
        return
    }
    state.spReassertCount = (state.spReassertCount ?: 0) + 1
    offenders.each { t ->
        if (t.currentValue("thermostatMode") != exp.mode) {
            t.setThermostatMode(exp.mode)
            logWarn "reassertSetpoints (attempt ${state.spReassertCount}/3): ${t.displayName} -> mode '${exp.mode}' re-sent"
        }
        if (exp.heat != null && num(t.currentValue("heatingSetpoint")) != exp.heat) {
            t.setHeatingSetpoint(exp.heat)
        }
        if (exp.cool != null && num(t.currentValue("coolingSetpoint")) != exp.cool) {
            t.setCoolingSetpoint(exp.cool)
        }
        logWarn "reassertSetpoints (attempt ${state.spReassertCount}/3): ${t.displayName} -> ${exp.mode} band values re-sent"
    }
    runIn(10, "reassertSetpoints", [overwrite: true])
}

// ---- fan duty cycle ----
def ensureFanCycle() {
    if (state.fanCycleActive) {
        logDebug "Fan duty cycle already running (phase: ${state.fanPhase})"
        return
    }
    startFanCycle()
}

def startFanCycle() {
    unschedule("fanOnPhase")
    unschedule("fanOffPhase")
    state.fanCycleActive = true
    enterOnPhase("starting fan duty cycle: ${fanActiveMinutes()} min ${settings.fanActiveMode ?: 'on'} / ${fanRestMinutes()} min auto")
}

def enterOnPhase(String note) {
    state.fanPhase = "on"
    state.fanReassertCount = 0
    setFanMode(settings.fanActiveMode ?: "on", note)
    runIn(fanActiveSeconds(), "fanOffPhase", [overwrite: true])
}

def fanOffPhase() {
    if (!state.fanCycleActive) return
    def open = openSensors()
    if (open) {
        logWarn "fanOffPhase: sensor(s) open (${open.join(', ')}) — stopping fan cycle"
        stopFanCycle()
        return
    }
    state.fanPhase = "off"
    state.fanReassertCount = 0
    setFanMode("auto", "fan rest phase (${fanRestMinutes()} min)")
    runIn(fanRestSeconds(), "fanOnPhase", [overwrite: true])
}

def fanOnPhase() {
    if (!state.fanCycleActive) return
    if (!settings.fanCycle) {
        stopFanCycle()
        return
    }
    def open = openSensors()
    if (open) {
        logWarn "fanOnPhase: sensor(s) open (${open.join(', ')}) — stopping fan cycle"
        stopFanCycle()
        return
    }
    enterOnPhase("fan duty cycle continuing")
}

def stopFanCycle(Boolean sendCommand = true) {
    if (!state.fanCycleActive) {
        unschedule("fanOnPhase")
        unschedule("fanOffPhase")
        return
    }
    unschedule("fanOnPhase")
    unschedule("fanOffPhase")
    state.fanCycleActive = false
    state.fanPhase = null
    state.fanReassertCount = 0
    if (sendCommand) {
        setFanMode("auto", "fan duty cycle stopped")
        logInfo "Fan duty cycle stopped; fan mode -> auto"
    } else {
        logInfo "Fan duty cycle timers canceled (no command sent)"
    }
}

def setFanMode(String mode, String note) {
    thermostats.each { t ->
        if (t.currentValue("thermostatFanMode") != mode) {
            t.setThermostatFanMode(mode)
            logInfo "${t.displayName}: fan mode -> ${mode}${note ? ' (' + note + ')' : ''}"
        } else {
            logDebug "${t.displayName}: fan already ${mode}${note ? ' (' + note + ')' : ''}"
        }
    }
}

def forceFanMode(String mode, String note) {
    thermostats.each { t ->
        t.setThermostatFanMode(mode)
        logInfo "${t.displayName}: fan mode -> ${mode}${note ? ' (' + note + ')' : ''}"
    }
}

// ---- helpers ----
def num(v) {
    if (v == null) return null
    try { return v.toString().toBigDecimal() } catch (ignored) { return null }
}

def intSetting(v, Integer fallback) {
    def n = num(v)
    return (n != null && n > 0) ? n.intValue() : fallback
}

def openSensors() {
    def sensors = (contactSensors instanceof List) ? contactSensors : (contactSensors ? [contactSensors] : [])
    return sensors.findAll { it.currentValue("contact") == "open" }?.collect { it.displayName }
}

def offDelayMinutes()    { return intSetting(settings.offDelayMinutes, 2) }
def coolDelayMinutes()   { return intSetting(settings.coolDelayMinutes, 5) }
def fanActiveMinutes()   { return intSetting(settings.fanOnMinutes, 30) }
def fanRestMinutes()     { return intSetting(settings.fanOffMinutes, 30) }
def stalenessHoursInt()  { return intSetting(settings.stalenessHours, 3) }

def offDelaySeconds()    { return (offDelayMinutes() * 60) as Integer }
def coolDelaySeconds()   { return (coolDelayMinutes() * 60) as Integer }
def fanActiveSeconds()   { return (fanActiveMinutes() * 60) as Integer }
def fanRestSeconds()     { return (fanRestMinutes() * 60) as Integer }
def stalenessMs()        { return stalenessHoursInt() * 3600000L }

def logInfo(msg) { log.info msg }
def logWarn(msg) { log.warn msg }
def logDebug(msg) { if (settings.logEnable) log.debug msg }
