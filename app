/**
 *  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except
 *  in compliance with the License. You may obtain a copy of the License at:
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software distributed under the License is distributed
 *  on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License
 *  for the specific language governing permissions and limitations under the License.
 *
 *    Nexia Thermostat Controller
 *
 *    - Requires Nexia Thermostat Manager App
 *    - Requires Nexia Thermostat Driver
 *
 *    Author: Jason Myers
 *    Date: 2026-10-28
 *
 * **	Modifications **
 *	Date		Who		    Description
 *	2026-10-28	inetjnky	Created for Hubitat
 *
 */

definition(
    name: "Nexia Thermostat Control",
    namespace: "inetjnky",
    author: "inetjnky",
    description: "Thermostat OFF when a contact sensor stays open (2 min); outdoor-temp rules with selectable primary/backup sources + auto failover and Pushover alerts; OFF band (40-50°F) runs the fan 30 min/hour; 5 min after all sensors close, re-applies rules. Watchdogs re-assert OFF, fan phase, and mode-band setpoints if the cloud loses a write.",
    category: "Convenience",
    iconUrl: "",
    iconX2Url: "",
    menu: "Automations",
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
        section("Contact sensors") {
            input "contactSensors", "capability.contactSensor",
                title: "Turn thermostat OFF when any of these stays open", multiple: true,
                required: false, submitOnChange: true
            if (contactSensors) {
                input "offDelayMinutes", "number",
                    title: "Minutes a sensor must stay open before OFF (timer restarts if another opens)",
                    defaultValue: 2, range: "1..120", required: true
                input "resumeDelayMinutes", "number",
                    title: "Minutes after ALL sensors close before re-applying outdoor temp rules",
                    defaultValue: 5, range: "1..120", required: true
            }
        }
        section("Outdoor temperature rules (°F)") {
            paragraph "At or above the mild threshold: AUTO, heat ${mildHeatSp ?: 65} / cool ${mildCoolSp ?: 71}<br/>" +
                "Between thresholds: OFF${fanCycle ? ' + fan duty cycle' : ''}<br/>" +
                "Below the cold threshold: AUTO, heat ${coldHeatSp ?: 72} / cool ${coldCoolSp ?: 80}"
            input "mildThreshold", "number", title: "Mild threshold — AUTO heat/cool at/above this", defaultValue: 50, required: true
            input "coldThreshold", "number", title: "Cold threshold — AUTO heat/cool below this", defaultValue: 40, required: true
            input "mildHeatSp", "number", title: "Heat setpoint, mild band", defaultValue: 65, required: true
            input "mildCoolSp", "number", title: "Cool setpoint, mild band", defaultValue: 71, required: true
            input "coldHeatSp", "number", title: "Heat setpoint, cold band", defaultValue: 72, required: true
            input "coldCoolSp", "number", title: "Cool setpoint, cold band", defaultValue: 80, required: true
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
                title: "Pushover notifications on failover / stale / recovery", defaultValue: true, submitOnChange: true
            if (notifyFailover) {
                input "pushoverDevices", "capability.notification",
                    title: "Pushover device(s) (created by Pushover Manager)",
                    required: true, multiple: true
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
                paragraph "ON phase = fan '${fanActiveMode ?: 'on'}'. 'on' runs continuously (exactly 30 min/hour with defaults); 'circulate' lets the thermostat duty-cycle internally (less actual runtime). OFF phase = fan 'auto'. The cycle pauses while any sensor is open and during the post-close resume delay."
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
    state.lastPrimaryTempMs = now()
    initialize()
    if (applyOnSave) evaluateNow()
}

def updated() {
    if (state.forcedOffBySensor == null) state.forcedOffBySensor = false
    if (state.lastPrimaryTempMs == null) state.lastPrimaryTempMs = now()
    unsubscribe()
    unschedule()
    initialize()
    if (applyOnSave) evaluateNow()
}

def initialize() {
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
    runEvery15Minutes("auditTempSource")
    // Recover a pending resume if the hub restarted mid-delay
    if (state.pendingResume) {
        runIn(resumeDelaySeconds(), "resumeCheck", [overwrite: true])
        logInfo "Hub restart during resume delay — resume re-scheduled in ${resumeDelayMinutes()} min"
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
        } else if (!state.pendingResume) {
            // Sensors closed while the hub was down: the close event was lost
            state.pendingResume = true
            runIn(resumeDelaySeconds(), "resumeCheck", [overwrite: true])
            logInfo "Restart after sensor-close during protection — resume re-scheduled in ${resumeDelayMinutes()} min"
        }
    }
    // Verify setpoints survived the restart if a band owns them
    if (state.appliedBand && !state.forcedOffBySensor && !state.pendingResume) {
        runIn(15, "reassertSetpoints", [overwrite: true])
        logInfo "Restart while '${state.appliedBand}' band owns setpoints — verification check in 15 s"
    }
}

// ---- sensor handlers ----
def sensorOpenHandler(evt) {
    logInfo "Sensor opened: ${evt.displayName}"
    if (state.pendingResume) {
        state.pendingResume = false
        unschedule("resumeCheck")
        logInfo "Pending resume canceled (sensor reopened)"
    }
    state.appliedBand = null
    state.spReassertCount = 0
    stopFanCycle()
    runIn(offDelaySeconds(), "closeoutCheck", [overwrite: true])
    logInfo "Thermostat will turn OFF in ${offDelayMinutes()} min if a sensor is still open"
}

def closeoutCheck() {
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
    // Sensor protection owns the thermostat state from here until resume
    state.forcedOffBySensor = true
}

def sensorCloseHandler(evt) {
    logInfo "Sensor closed: ${evt.displayName}"
    def open = openSensors()
    if (open) {
        logDebug "Still open: ${open.join(', ')} — no action"
        return
    }
    // All closed: cancel a pending OFF that hasn't fired yet
    unschedule("closeoutCheck")
    if (state.forcedOffBySensor) {
        state.pendingResume = true
        runIn(resumeDelaySeconds(), "resumeCheck", [overwrite: true])
        logInfo "All sensors closed — re-evaluating outdoor temp rules in ${resumeDelayMinutes()} min"
    } else {
        logDebug "All sensors closed; thermostat was not forced off — nothing to resume"
    }
}

def resumeCheck() {
    state.pendingResume = false
    def open = openSensors()
    if (open) {
        logWarn "resumeCheck: sensor(s) open again (${open.join(', ')}) — staying off"
        return
    }
    state.forcedOffBySensor = false
    state.offReassertCount = 0
    state.spReassertCount = 0
    logInfo "Resume delay elapsed — re-applying outdoor temperature rules"
    evaluateOutdoorRules()
}

// ---- outdoor temperature: primary, backup, failover ----
def primaryTempHandler(evt) {
    state.lastPrimaryTempMs = now()   // any event proves the primary is alive
    logInfo "Outdoor temperature (primary/${evt.name}): ${evt.value}°F"
    def open = openSensors()
    if (open) {
        logInfo "Sensor(s) open (${open.join(', ')}) — outdoor temp rules suppressed; sensor protection handles OFF if it stays open"
        return
    }
    if (state.pendingResume) {
        logInfo "Within post-close delay — rules will be applied when the ${resumeDelayMinutes()} min resume fires"
        return
    }
    evaluateOutdoorRules()
}

def backupTempHandler(evt) {
    logInfo "Backup outdoor temperature: ${evt.value}°F"
    if (state.tempSourceActive == "primary") {
        logDebug "Primary is active — backup reading noted, no action"
        return
    }
    def open = openSensors()
    if (open) {
        logInfo "Sensor(s) open — rules suppressed"
        return
    }
    if (state.pendingResume) {
        logInfo "Within post-close delay — rules will be applied when the resume fires"
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
            notifyUser("Primary outdoor temp stale (last update ${ageH}) — failing over to backup ${backupOutdoorSensor?.displayName} (${src.backup}°F)")
            break
        case "primary-stale":
            logWarn "Primary outdoor temp stale (last update ${ageH}), no backup available — rules frozen on last known ${src.primary}°F"
            notifyUser("Primary outdoor temp stale (last update ${ageH}), no backup available — thermostat rules frozen on last known ${src.primary}°F")
            break
        case "primary":
            if (prev != null) {
                logInfo "Primary outdoor temp recovered — resuming primary source"
                notifyUser("Primary outdoor temp recovered — using primary source again")
            }
            break
        case "none":
            logWarn "No outdoor temperature available from primary or backup — rules paused"
            notifyUser("No outdoor temperature available (primary and backup) — thermostat rules paused")
            break
    }
}

def primaryAgeHours() {
    if (state.lastPrimaryTempMs == null) return "unknown"
    return "${String.format('%.1f', (now() - state.lastPrimaryTempMs) / 3600000.0d)} h"
}

def auditTempSource() {
    def open = openSensors()
    if (open) { logDebug "audit: sensor(s) open — skip"; return }
    if (state.pendingResume) { logDebug "audit: resume pending — skip"; return }
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

def notifyUser(String msg) {
    def line = "Nexia Thermostat Guard: ${msg}"
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
    def open = openSensors()
    if (open) {
        if (state.pendingResume) {
            state.pendingResume = false
            unschedule("resumeCheck")
        }
        state.appliedBand = null
        state.spReassertCount = 0
        stopFanCycle()
        runIn(offDelaySeconds(), "closeoutCheck", [overwrite: true])
        logInfo "Sensor(s) open at save (${open.join(', ')}) — OFF check scheduled in ${offDelayMinutes()} min"
        return
    }
    if (state.pendingResume) {
        logInfo "Resume already scheduled — rules will apply in ≤${resumeDelayMinutes()} min"
        return
    }
    evaluateOutdoorRules()
}

def applyRules(Map src) {
    def outdoor = src.temp
    if (outdoor == null) {
        logWarn "No outdoor temperature available — skipping rule application"
        state.lastEvalSkipped = true
        return
    }
    state.lastEvalSkipped = false
    def mild = num(settings.mildThreshold) ?: 50
    def cold = num(settings.coldThreshold) ?: 40
    def band = (outdoor < cold) ? "cold" : (outdoor < mild) ? "off" : "mild"
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
            case "mild":
                stopFanCycle()
                applyAuto(t, num(settings.mildHeatSp) ?: 65, num(settings.mildCoolSp) ?: 71, "mild")
                break
            case "cold":
                stopFanCycle()
                applyAuto(t, num(settings.coldHeatSp) ?: 72, num(settings.coldCoolSp) ?: 80, "cold")
                break
        }
    }
}

def applyAuto(t, heatSp, coolSp, band) {
    if (t.currentValue("thermostatMode") != "auto") {
        t.setThermostatMode("auto")
        logInfo "${t.displayName}: mode -> auto"
    }
    if (num(t.currentValue("heatingSetpoint")) != heatSp) {
        t.setHeatingSetpoint(heatSp)
        logInfo "${t.displayName}: heat setpoint -> ${heatSp}°F"
    }
    if (num(t.currentValue("coolingSetpoint")) != coolSp) {
        t.setCoolingSetpoint(coolSp)
        logInfo "${t.displayName}: cool setpoint -> ${coolSp}°F"
    }
    if (settings.applyPermanentHold) {
        t.setHold("Permanent Hold")
        logInfo "${t.displayName}: permanent hold requested"
    }
    // This band now owns the setpoints — watchdog expectations update
    state.appliedBand = band
    state.spReassertCount = 0
}

// ---- watchdogs (cloud write verification) ----
def modeHandler(evt) {
    logDebug "thermostatMode event: ${evt.displayName} -> ${evt.value}"
    if (!state.forcedOffBySensor || state.pendingResume) return
    if (evt.value == "off") {
        state.offReassertCount = 0
        return
    }
    // Should be OFF but the attribute says otherwise (stale poll or lost write)
    logWarn "${evt.displayName}: expected OFF but mode shows '${evt.value}' — re-check in 10 s"
    runIn(10, "reassertOff", [overwrite: true])
}

def reassertOff() {
    if (!state.forcedOffBySensor || state.pendingResume) return
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
    if (!state.fanCycleActive || state.pendingResume) return
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
    if (!state.fanCycleActive || state.pendingResume) return
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

def setpointHandler(evt) {
    logDebug "${evt.name} event: ${evt.displayName} -> ${evt.value}"
    if (!state.appliedBand || state.forcedOffBySensor || state.pendingResume) return
    if (openSensors()) return
    def expected = expectedSetpoints()
    if (expected == null) { state.appliedBand = null; return }
    def expVal = (evt.name == "heatingSetpoint") ? expected.heat : expected.cool
    if (num(evt.value) == expVal) {
        state.spReassertCount = 0
        return
    }
    logWarn "${evt.displayName}: ${evt.name} should be ${expVal}°F but shows ${evt.value} — re-check in 10 s"
    runIn(10, "reassertSetpoints", [overwrite: true])
}

def expectedSetpoints() {
    if (state.appliedBand == "cold") {
        return [heat: num(settings.coldHeatSp) ?: 72, cool: num(settings.coldCoolSp) ?: 80]
    }
    if (state.appliedBand == "mild") {
        return [heat: num(settings.mildHeatSp) ?: 65, cool: num(settings.mildCoolSp) ?: 71]
    }
    return null
}

def reassertSetpoints() {
    if (!state.appliedBand || state.forcedOffBySensor || state.pendingResume) return
    if (openSensors()) return
    def expected = expectedSetpoints()
    if (expected == null) return
    def offenders = thermostats.findAll {
        num(it.currentValue("heatingSetpoint")) != expected.heat ||
        num(it.currentValue("coolingSetpoint")) != expected.cool
    }
    if (!offenders) {
        logDebug "reassertSetpoints: setpoints match ${state.appliedBand} band (transient resolved)"
        state.spReassertCount = 0
        return
    }
    if ((state.spReassertCount ?: 0) >= 3) {
        logWarn "Setpoints did not stick after 3 re-send attempts (${offenders.collect { it.displayName }.join(', ')}) — expected heat ${expected.heat}°F / cool ${expected.cool}°F. If the driver logs show clamping, the setpoints are outside the thermostat's reported range; otherwise check the Nexia cloud/driver logs."
        return
    }
    state.spReassertCount = (state.spReassertCount ?: 0) + 1
    offenders.each { t ->
        if (num(t.currentValue("heatingSetpoint")) != expected.heat) {
            t.setHeatingSetpoint(expected.heat)
        }
        if (num(t.currentValue("coolingSetpoint")) != expected.cool) {
            t.setCoolingSetpoint(expected.cool)
        }
        logWarn "reassertSetpoints (attempt ${state.spReassertCount}/3): ${t.displayName} -> heat ${expected.heat}°F / cool ${expected.cool}°F re-sent"
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

def stopFanCycle() {
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
    setFanMode("auto", "fan duty cycle stopped")
    logInfo "Fan duty cycle stopped; fan mode -> auto"
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
def resumeDelayMinutes() { return intSetting(settings.resumeDelayMinutes, 5) }
def fanActiveMinutes()   { return intSetting(settings.fanOnMinutes, 30) }
def fanRestMinutes()     { return intSetting(settings.fanOffMinutes, 30) }
def stalenessHoursInt()  { return intSetting(settings.stalenessHours, 3) }

def offDelaySeconds()    { return (offDelayMinutes() * 60) as Integer }
def resumeDelaySeconds() { return (resumeDelayMinutes() * 60) as Integer }
def fanActiveSeconds()   { return (fanActiveMinutes() * 60) as Integer }
def fanRestSeconds()     { return (fanRestMinutes() * 60) as Integer }
def stalenessMs()        { return stalenessHoursInt() * 3600000L }

def logInfo(msg) { log.info msg }
def logWarn(msg) { log.warn msg }
def logDebug(msg) { if (settings.logEnable) log.debug msg }
