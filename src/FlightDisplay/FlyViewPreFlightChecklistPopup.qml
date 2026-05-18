/****************************************************************************
 *
 * (c) 2009-2020 QGROUNDCONTROL PROJECT <http://www.qgroundcontrol.org>
 *
 * QGroundControl is licensed according to the terms in the file
 * COPYING.md in the root of the source code directory.
 *
 ****************************************************************************/

import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs

import QGroundControl
import QGroundControl.Vehicle
import QGroundControl.Controls

/// Popup container for preflight checklists
QGCPopupDialog {
    id:         _root
    title:      qsTr("Pre-Flight Checklist")
    buttons:    Dialog.Close

    property var    _activeVehicle:     QGroundControl.multiVehicleManager.activeVehicle
    property bool   _useChecklist:      QGroundControl.settingsManager.appSettings.useChecklist.rawValue && QGroundControl.corePlugin.options.preFlightChecklistUrl.toString().length
    property bool   _enforceChecklist:  _useChecklist && QGroundControl.settingsManager.appSettings.enforceChecklist.rawValue
    property bool   _checklistComplete: _activeVehicle && (_activeVehicle.checkListState === Vehicle.CheckListPassed)

    on_ActiveVehicleChanged: _showPreFlightChecklistIfNeeded()

    Connections {
        target:                             mainWindow
        onShowPreFlightChecklistIfNeeded:   _root._showPreFlightChecklistIfNeeded()
    }

    function _showPreFlightChecklistIfNeeded() {
        if (_activeVehicle && !_checklistComplete && _enforceChecklist) {
            popupTimer.restart()
        }
    }

    Timer {
        id:             popupTimer
        interval:       1000
        repeat:         false
        onTriggered: {
            if (!_checklistComplete) {
                _root.open()
            } else {
                _root.close()
            }
        }
    }

    Item {
    id: checklistContent
    width:  1050
    height: gremsyReadyPanel.height + checklistTitle.height + separator.height + checkList.height + 54

    Column {
        anchors.fill: parent
        spacing: 14

        Loader {
}

Rectangle {
            id: gremsyReadyPanel
            width: parent.width
            height: 820
            radius: 8
            color: "#12232A"
            border.color: "#00AEEF"
            border.width: 2

            property var activeVehicle: QGroundControl.multiVehicleManager.activeVehicle
            property bool safetyConfirmed: false
            property bool vehicleConnected: activeVehicle !== null
            property bool vehicleArmed: vehicleConnected ? activeVehicle.armed : false
            property bool readyAllowed: vehicleConnected && safetyConfirmed && !vehicleArmed

            property var commandQueue: []
            property int commandIndex: 0
            property bool commandRunning: false
            property bool commandPaused: false
            property int currentWaitSeconds: 1
            property bool gremsyMotorTestActive: false
            property double motorTestArmGraceUntil: 0
            property string testProfileOverride: "AUTO"   // AUTO, QUADCOPTER, QUADPLANE
            property bool currentTestRequiresManualVtolVerify: false
            property string manualVtolVerifyText: ""
            property bool pwmVerifyActive: false
            property int pwmVerifyThreshold: 40
            property int pwmServo1Base: 0
            property int pwmServo2Base: 0
            property int pwmServo3Base: 0
            property int pwmServo4Base: 0
            property int pwmServo9Base: 0
            property bool vtolRestoreVerifyOk: true
            property string vtolRestoreVerifyText: ""
            property bool vtolDirectOutputMode: false
            property int servo1FunctionBackup: -999
            property int servo2FunctionBackup: -999
            property int servo3FunctionBackup: -999
            property int servo4FunctionBackup: -999
            property int servo9FunctionBackup: -999
            property string commandProgressText: "Chưa chạy"
            property real commandProgressRatio: 0.0
            property string commandLog: ""

            function startCommandQueue(commands, message) {
                commandSequenceTimer.stop()

                commandLog = ""
                appendCommandLog("CLICK: Start command queue requested.")

                if (!vehicleConnectedSafe()) {
                    resultText.text = "Chưa nhận máy bay. Không thể chạy Gremsy Ready."
                    appendCommandLog("BLOCKED: No vehicle connected.")
                    return
                }

                if (!safetyConfirmed) {
                    resultText.text = "Vui lòng xác nhận đã tháo cánh/quạt và khu vực test an toàn."
                    appendCommandLog("BLOCKED: Safety confirmation missing.")
                    return
                }

                if (shouldLockForFlight()) {
                    resultText.text = "Máy bay đang ARM/Flying. Gremsy Ready không gửi lệnh test."
                    appendCommandLog("BLOCKED: Vehicle armed/flying.")
                    lockForFlight()
                    return
                }

                commandQueue = commands
                commandIndex = 0
                commandRunning = true
                commandPaused = false
                gremsyMotorTestActive = false
                currentWaitSeconds = 1
                commandProgressRatio = 0.0

                waitingUserConfirm = false
                testFailed = false
                motorPass = false
                servoPass = false
                fullPass = false
                lastResult = "NOT_COMPLETED"
                finalStatusText = "GREMSY READY: ĐANG TEST"

                commandProgressText = "Bắt đầu: 0/" + commandQueue.length + " - Gap " + commandGapSeconds + "s"
                resultText.text = message + " Gap giữa các lệnh: " + commandGapSeconds + "s."

                appendCommandLog("START: " + message)
                appendCommandLog("PROFILE: " + detectedDroneType() + " | override=" + testProfileOverride + " | auto=" + autoDetectedDroneType() + " | Q_ENABLE=" + getVehicleParamValue("Q_ENABLE"))
                sendNextQueuedCommand()
            }

            function pauseGremsyTest() {
                if (!commandRunning) {
                    appendCommandLog("PAUSE ignored: no command is running.")
                    return
                }

                commandPaused = true
                commandSequenceTimer.stop()
                commandProgressText = "Đã PAUSE. Lệnh đã gửi xuống ArduPilot sẽ chạy hết bước hiện tại; app không gửi lệnh tiếp theo."
                appendCommandLog("PAUSED: Queue paused before next command.")
            }

            function continueGremsyTest() {
                if (!commandRunning) {
                    appendCommandLog("CONTINUE ignored: no command is running.")
                    return
                }

                commandPaused = false
                appendCommandLog("CONTINUE: Queue resumed.")
                sendNextQueuedCommand()
            }

            function sendNextQueuedCommand() {
                if (!commandRunning) {
                    appendCommandLog("STOPPED: commandRunning = false.")
                    return
                }

                if (commandPaused) {
                    appendCommandLog("PAUSED: Queue is paused, not sending next command.")
                    return
                }

                if (commandIndex >= commandQueue.length) {
                    commandSequenceTimer.stop()
                    commandRunning = false
                    commandPaused = false
                    gremsyMotorTestActive = false
                    motorTestArmGraceUntil = 0
                    currentWaitSeconds = 1
                    commandProgressRatio = 1.0
                    commandProgressText = "Hoàn tất: " + commandQueue.length + "/" + commandQueue.length
                    waitingUserConfirm = true
                    finalStatusText = "GREMSY READY: CHỜ XÁC NHẬN PASS/FAIL"
                    if (currentTestRequiresManualVtolVerify) {
                        resultText.text = "Auto test lift motor hoàn tất. Push/Servo: Manual Verify. Chọn PASS/FAIL."
                        capturePwmVerifyBaseline()
                        appendCommandLog("PWM VERIFY ACTIVE: move/check push motor and control surfaces, then confirm PASS/FAIL.")
                        appendCommandLog("MANUAL VERIFY REQUIRED after lift motor auto test.")
                        appendCommandLog(manualVtolVerifyText)
                    } else {
                        resultText.text = "Đã gửi xong toàn bộ lệnh. Vui lòng quan sát thực tế rồi chọn PASS hoặc FAIL."
                    }
                    var restoreOk = restoreVtolDirectOutputTest()
                    if (!restoreOk) {
                        appendCommandLog("DONE WITH ERROR: Restore verification failed.")
                        return
                    }

                    appendCommandLog("DONE: Hoàn tất toàn bộ queue, chờ PASS/FAIL.")
                    return
                }

                if (shouldLockForFlight()) {
                    appendCommandLog("LOCK BEFORE SEND: Vehicle armed/flying.")
                    lockForFlight()
                    return
                }

                var c = commandQueue[commandIndex]
                var currentNumber = commandIndex + 1

                currentWaitSeconds = c.waitSeconds !== undefined ? c.waitSeconds : commandGapSeconds

                if (c.cmd === 209) {
                    gremsyMotorTestActive = true
                    motorTestArmGraceUntil = new Date().getTime() + (currentWaitSeconds * 1000) + 1500
                } else {
                    gremsyMotorTestActive = false
                    motorTestArmGraceUntil = 0
                }

                var waitText = c.waitSeconds !== undefined ?
                               " | Chờ " + currentWaitSeconds + "s" :
                               " | Gap " + commandGapSeconds + "s"

                commandProgressText = "Đang gửi lệnh " + currentNumber + "/" + commandQueue.length + ": " + c.label + waitText
                commandProgressRatio = currentNumber / commandQueue.length

                appendCommandLog("SEND " + currentNumber + "/" + commandQueue.length + ": " + c.label + " | cmd=" + c.cmd + " | profile=" + detectedDroneType() + " | wait=" + currentWaitSeconds + "s")

                commandIndex = commandIndex + 1
                sendCommand(c.cmd, c.p1, c.p2, c.p3, c.p4, c.p5, c.p6, c.p7)

                commandSequenceTimer.restart()
            }

            property int liftMotorThrottle: 10
            property int motorTestDuration: 5
            property int commandGapSeconds: 5
            property int pushMotorPwm: 1200
            property int servoDelta: 200

            property string testerName: ""
            property string testDate: Qt.formatDate(new Date(), "yyyy-MM-dd")
            property int vtolTestCount: 1
            property string testNote: ""
            property string lastResult: "NOT_COMPLETED"
            property string csvPreview: ""
            property string csvSaveStatus: ""

            property bool motorPass: false
            property bool servoPass: false
            property bool fullPass: false

            property bool testFailed: false
            property bool waitingUserConfirm: false
            property string finalStatusText: "GREMSY READY: CHƯA HOÀN TẤT"

            function resetResult() {
                commandSequenceTimer.stop()
                commandQueue = []
                commandIndex = 0
                commandRunning = false
                commandPaused = false
                gremsyMotorTestActive = false
                commandProgressRatio = 0.0
                currentTestRequiresManualVtolVerify = false
                manualVtolVerifyText = ""
                pwmVerifyActive = false
                pwmServo1Base = 0
                pwmServo2Base = 0
                pwmServo3Base = 0
                pwmServo4Base = 0
                pwmServo9Base = 0
                commandProgressText = "Chưa chạy"
                commandLog = ""
                resultText.text = "Đã reset test về trạng thái ban đầu."

                motorPass = false
                servoPass = false
                fullPass = false
                testFailed = false
                waitingUserConfirm = false
                lastResult = "NOT_COMPLETED"
                finalStatusText = "GREMSY READY: CHƯA HOÀN TẤT"
                csvPreview = ""
                csvSaveStatus = ""

                resultText.text = "Đã reset test về trạng thái ban đầu."
            }

            function pauseTest() {
                if (!commandRunning || commandPaused) {
                    return
                }

                commandPaused = true
                commandSequenceTimer.stop()
                commandProgressText = "ĐÃ PAUSE tại lệnh " + commandIndex + "/" + commandQueue.length
                resultText.text = "Đã tạm dừng tiến trình. Nhấn Continue để chạy tiếp."
            }

            function continueTest() {
                if (!commandRunning || !commandPaused) {
                    return
                }

                commandPaused = false
                resultText.text = "Tiếp tục test từ lệnh " + (commandIndex + 1) + "/" + commandQueue.length + "."
                commandSequenceTimer.start()
            }

            function vehicleConnectedSafe() {
                return _activeVehicle !== null && _activeVehicle !== undefined
            }

            function vehicleArmedSafe() {
                return vehicleConnectedSafe() && _activeVehicle.armed
            }

            function vehicleFlyingSafe() {
                return vehicleConnectedSafe() && _activeVehicle.flying
            }

            

            

            

            

            

            

            

            

            

            

            

            function getVehicleParamValue(paramName) {
                if (!vehicleConnectedSafe()) {
                    return undefined
                }

                try {
                    if (_activeVehicle.gremsyGetParam !== undefined) {
                        return _activeVehicle.gremsyGetParam(paramName)
                    }
                } catch(e) {
                    appendCommandLog("PARAM GET ERROR: " + paramName + " - " + e)
                }

                return undefined
            }

            function hasQuadPlaneParameter() {
                var qEnable = getVehicleParamValue("Q_ENABLE")
                if (qEnable === undefined || qEnable === null || qEnable === "") {
                    return false
                }
                return Number(qEnable) === 1
            }

            function autoDetectedDroneType() {
                if (!vehicleConnectedSafe()) {
                    return "NO_VEHICLE"
                }

                if (hasQuadPlaneParameter()) {
                    return "QUADPLANE"
                }

                try {
                    if (_activeVehicle.vtol === true) {
                        return "QUADPLANE"
                    }

                    if (_activeVehicle.fixedWing === true && _activeVehicle.multiRotor === true) {
                        return "QUADPLANE"
                    }

                    if (_activeVehicle.vehicleType !== undefined) {
                        var vt = Number(_activeVehicle.vehicleType)

                        if (vt >= 19 && vt <= 25) {
                            return "QUADPLANE"
                        }

                        if (vt === 2) {
                            return "QUADCOPTER"
                        }
                    }

                    if (_activeVehicle.multiRotor === true) {
                        return "QUADCOPTER"
                    }

                    if (_activeVehicle.fixedWing === true) {
                        return "FIXED_WING"
                    }
                } catch(e) {
                }

                return "UNKNOWN"
            }

            function detectedDroneType() {
                if (testProfileOverride === "QUADPLANE") {
                    return "QUADPLANE"
                }

                if (testProfileOverride === "QUADCOPTER") {
                    return "QUADCOPTER"
                }

                return autoDetectedDroneType()
            }

            function isQuadPlaneProfile() {
                return detectedDroneType() === "QUADPLANE"
            }

            function isQuadcopterProfile() {
                return detectedDroneType() === "QUADCOPTER"
            }

            function profileDisplayText() {
                if (testProfileOverride === "AUTO") {
                    return "Auto: " + autoDetectedDroneType()
                }

                if (testProfileOverride === "QUADPLANE") {
                    return "VTOL / QuadPlane"
                }

                if (testProfileOverride === "QUADCOPTER") {
                    return "Quadcopter"
                }

                return detectedDroneType()
            }

            function testNoLabelText() {
                return isQuadPlaneProfile() ? "VTOL Test No." : "Quadcopter Test No."
            }

            function setTestProfileOverride(profile) {
                testProfileOverride = profile
                resultText.text = "Đã chọn test profile: " + profileDisplayText()
                appendCommandLog("PROFILE SELECTED: " + profileDisplayText())
            }

            function servoRawValue(channel) {
                if (!vehicleConnectedSafe()) {
                    return 0
                }

                if (channel === 1) return _activeVehicle.gremsyServo1Raw
                if (channel === 2) return _activeVehicle.gremsyServo2Raw
                if (channel === 3) return _activeVehicle.gremsyServo3Raw
                if (channel === 4) return _activeVehicle.gremsyServo4Raw
                if (channel === 9) return _activeVehicle.gremsyServo9Raw

                return 0
            }

            function capturePwmVerifyBaseline() {
                pwmServo1Base = servoRawValue(1)
                pwmServo2Base = servoRawValue(2)
                pwmServo3Base = servoRawValue(3)
                pwmServo4Base = servoRawValue(4)
                pwmServo9Base = servoRawValue(9)
                pwmVerifyActive = true

                appendCommandLog("PWM BASELINE: S1=" + pwmServo1Base +
                                 " S2=" + pwmServo2Base +
                                 " S3=" + pwmServo3Base +
                                 " S4=" + pwmServo4Base +
                                 " S9=" + pwmServo9Base)
            }

            function pwmDelta(channel) {
                if (channel === 1) return Math.abs(servoRawValue(1) - pwmServo1Base)
                if (channel === 2) return Math.abs(servoRawValue(2) - pwmServo2Base)
                if (channel === 3) return Math.abs(servoRawValue(3) - pwmServo3Base)
                if (channel === 4) return Math.abs(servoRawValue(4) - pwmServo4Base)
                if (channel === 9) return Math.abs(servoRawValue(9) - pwmServo9Base)
                return 0
            }

            function pwmCheckText(channel, name) {
                var raw = servoRawValue(channel)
                var delta = pwmDelta(channel)
                var status = delta >= pwmVerifyThreshold ? "OK" : "WAIT"
                return name + ": " + raw + " Δ" + delta + " " + status
            }

            function pwmVerifyOverallText() {
                if (!pwmVerifyActive) {
                    return "PWM Verify: chờ hoàn tất lift motor để lấy baseline."
                }

                var pushOk = pwmDelta(3) >= pwmVerifyThreshold
                var aileOk = pwmDelta(1) >= pwmVerifyThreshold || pwmDelta(9) >= pwmVerifyThreshold
                var vtailOk = pwmDelta(2) >= pwmVerifyThreshold || pwmDelta(4) >= pwmVerifyThreshold

                return "PWM Verify: Push=" + (pushOk ? "OK" : "WAIT") +
                       " | Aileron=" + (aileOk ? "OK" : "WAIT") +
                       " | V-tail=" + (vtailOk ? "OK" : "WAIT")
            }

            function vtolManualVerifyDescription() {
                return "MANUAL VERIFY: Push SERVO3; Control SERVO1/2/4/9."
            }

            function csvTestNote() {
                if (currentTestRequiresManualVtolVerify) {
                    if (testNote.length > 0) {
                        return testNote + " | " + vtolManualVerifyDescription()
                    }
                    return vtolManualVerifyDescription()
                }

                return testNote
            }

            function setVehicleParamValue(paramName, value) {
                if (!vehicleConnectedSafe()) {
                    appendCommandLog("PARAM SET FAIL: no vehicle for " + paramName)
                    return false
                }

                try {
                    if (_activeVehicle.gremsySetParam !== undefined) {
                        var ok = _activeVehicle.gremsySetParam(paramName, value)
                        appendCommandLog((ok ? "PARAM SET OK: " : "PARAM SET FAIL: ") + paramName + "=" + value)
                        return ok
                    }
                } catch(e) {
                    appendCommandLog("PARAM SET ERROR: " + paramName + " - " + e)
                }

                appendCommandLog("PARAM SET FAIL: C++ gremsySetParam unavailable for " + paramName)
                return false
            }

            function prepareVtolDirectOutputTest() {
                if (!isQuadPlaneProfile()) {
                    appendCommandLog("DIRECT OUTPUT BLOCKED: not QUADPLANE profile.")
                    return false
                }

                if (shouldLockForFlight()) {
                    appendCommandLog("DIRECT OUTPUT BLOCKED: vehicle armed/flying.")
                    return false
                }

                servo1FunctionBackup = Number(getVehicleParamValue("SERVO1_FUNCTION"))
                servo2FunctionBackup = Number(getVehicleParamValue("SERVO2_FUNCTION"))
                servo3FunctionBackup = Number(getVehicleParamValue("SERVO3_FUNCTION"))
                servo4FunctionBackup = Number(getVehicleParamValue("SERVO4_FUNCTION"))
                servo9FunctionBackup = Number(getVehicleParamValue("SERVO9_FUNCTION"))

                appendCommandLog("BACKUP FUNCTIONS: S1=" + servo1FunctionBackup +
                                 " S2=" + servo2FunctionBackup +
                                 " S3=" + servo3FunctionBackup +
                                 " S4=" + servo4FunctionBackup +
                                 " S9=" + servo9FunctionBackup)

                var ok = true
                ok = setVehicleParamValue("SERVO1_FUNCTION", 0) && ok
                ok = setVehicleParamValue("SERVO2_FUNCTION", 0) && ok
                ok = setVehicleParamValue("SERVO3_FUNCTION", 0) && ok
                ok = setVehicleParamValue("SERVO4_FUNCTION", 0) && ok
                ok = setVehicleParamValue("SERVO9_FUNCTION", 0) && ok

                // Đọc lại ngay giá trị cache trong QGC để kiểm tra tối thiểu.
                var s1 = Number(getVehicleParamValue("SERVO1_FUNCTION"))
                var s2 = Number(getVehicleParamValue("SERVO2_FUNCTION"))
                var s3 = Number(getVehicleParamValue("SERVO3_FUNCTION"))
                var s4 = Number(getVehicleParamValue("SERVO4_FUNCTION"))
                var s9 = Number(getVehicleParamValue("SERVO9_FUNCTION"))

                appendCommandLog("VERIFY FUNCTIONS: S1=" + s1 + " S2=" + s2 + " S3=" + s3 + " S4=" + s4 + " S9=" + s9)

                var verifyOk = (s1 === 0 && s2 === 0 && s3 === 0 && s4 === 0 && s9 === 0)

                vtolDirectOutputMode = ok && verifyOk

                if (vtolDirectOutputMode) {
                    appendCommandLog("DIRECT OUTPUT ENABLED: SERVO1/2/3/4/9 = 0.")
                    capturePwmVerifyBaseline()
                } else {
                    appendCommandLog("DIRECT OUTPUT FAILED: SERVO_FUNCTION chưa về 0. Không nên chạy Push/Servo.")
                }

                return vtolDirectOutputMode
            }

            function restoreVtolDirectOutputTest() {
                if (!vtolDirectOutputMode) {
                    return true
                }

                appendCommandLog("RESTORE SERVO FUNCTIONS...")

                if (servo1FunctionBackup !== -999) setVehicleParamValue("SERVO1_FUNCTION", servo1FunctionBackup)
                if (servo2FunctionBackup !== -999) setVehicleParamValue("SERVO2_FUNCTION", servo2FunctionBackup)
                if (servo3FunctionBackup !== -999) setVehicleParamValue("SERVO3_FUNCTION", servo3FunctionBackup)
                if (servo4FunctionBackup !== -999) setVehicleParamValue("SERVO4_FUNCTION", servo4FunctionBackup)
                if (servo9FunctionBackup !== -999) setVehicleParamValue("SERVO9_FUNCTION", servo9FunctionBackup)

                var s1 = Number(getVehicleParamValue("SERVO1_FUNCTION"))
                var s2 = Number(getVehicleParamValue("SERVO2_FUNCTION"))
                var s3 = Number(getVehicleParamValue("SERVO3_FUNCTION"))
                var s4 = Number(getVehicleParamValue("SERVO4_FUNCTION"))
                var s9 = Number(getVehicleParamValue("SERVO9_FUNCTION"))

                var ok1 = (servo1FunctionBackup === -999) || (s1 === servo1FunctionBackup)
                var ok2 = (servo2FunctionBackup === -999) || (s2 === servo2FunctionBackup)
                var ok3 = (servo3FunctionBackup === -999) || (s3 === servo3FunctionBackup)
                var ok4 = (servo4FunctionBackup === -999) || (s4 === servo4FunctionBackup)
                var ok9 = (servo9FunctionBackup === -999) || (s9 === servo9FunctionBackup)

                vtolRestoreVerifyOk = ok1 && ok2 && ok3 && ok4 && ok9

                vtolRestoreVerifyText =
                    "RESTORE VERIFY: " +
                    "S1=" + s1 + "/" + servo1FunctionBackup + " " +
                    "S2=" + s2 + "/" + servo2FunctionBackup + " " +
                    "S3=" + s3 + "/" + servo3FunctionBackup + " " +
                    "S4=" + s4 + "/" + servo4FunctionBackup + " " +
                    "S9=" + s9 + "/" + servo9FunctionBackup

                appendCommandLog(vtolRestoreVerifyText)

                vtolDirectOutputMode = false
                vtolRestoreVerifyOk = true
                vtolRestoreVerifyText = ""

                if (vtolRestoreVerifyOk) {
                    pwmVerifyActive = false
                    appendCommandLog("RESTORE VERIFY OK: SERVO functions restored.")
                    return true
                }

                testFailed = true
                waitingUserConfirm = false
                finalStatusText = "GREMSY READY: RESTORE FAILED / NOT READY"
                resultText.text = "LỖI: Không restore đúng SERVO_FUNCTION sau test. Không được bay. Vui lòng kiểm tra SERVO1/2/3/4/9_FUNCTION."
                commandProgressText = "Restore failed - kiểm tra parameter trước khi bay."
                appendCommandLog("RESTORE VERIFY FAILED: Aircraft NOT READY.")

                return false
            }

            function buildVtolPushServoDirectCommands() {
                var hi = 1500 + servoDelta
                var lo = 1500 - servoDelta
                var center = 1500
                var shortGap = 0.5

                return [
                    // Push motor / throttle
                    { label: "Push SERVO3 -> PWM " + pushMotorPwm, cmd: 183, p1: 3, p2: pushMotorPwm, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: commandGapSeconds },
                    { label: "Push SERVO3 -> Idle",                 cmd: 183, p1: 3, p2: 1000,         p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: commandGapSeconds },

                    // Aileron mix - roll right: SERVO1 high, SERVO9 low
                    { label: "Aileron Mix -> Roll Right S1 High", cmd: 183, p1: 1, p2: hi, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: shortGap },
                    { label: "Aileron Mix -> Roll Right S9 Low",  cmd: 183, p1: 9, p2: lo, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: commandGapSeconds },
                    { label: "Aileron Mix -> Center S1",          cmd: 183, p1: 1, p2: center, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: shortGap },
                    { label: "Aileron Mix -> Center S9",          cmd: 183, p1: 9, p2: center, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: commandGapSeconds },

                    // Aileron mix - roll left: SERVO1 low, SERVO9 high
                    { label: "Aileron Mix -> Roll Left S1 Low",   cmd: 183, p1: 1, p2: lo, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: shortGap },
                    { label: "Aileron Mix -> Roll Left S9 High",  cmd: 183, p1: 9, p2: hi, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: commandGapSeconds },
                    { label: "Aileron Mix -> Center S1",          cmd: 183, p1: 1, p2: center, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: shortGap },
                    { label: "Aileron Mix -> Center S9",          cmd: 183, p1: 9, p2: center, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: commandGapSeconds },

                    // V-tail pitch up: SERVO2 high, SERVO4 high
                    { label: "V-tail Mix -> Pitch Up S2 High",    cmd: 183, p1: 2, p2: hi, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: shortGap },
                    { label: "V-tail Mix -> Pitch Up S4 High",    cmd: 183, p1: 4, p2: hi, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: commandGapSeconds },
                    { label: "V-tail Mix -> Center S2",           cmd: 183, p1: 2, p2: center, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: shortGap },
                    { label: "V-tail Mix -> Center S4",           cmd: 183, p1: 4, p2: center, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: commandGapSeconds },

                    // V-tail pitch down: SERVO2 low, SERVO4 low
                    { label: "V-tail Mix -> Pitch Down S2 Low",   cmd: 183, p1: 2, p2: lo, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: shortGap },
                    { label: "V-tail Mix -> Pitch Down S4 Low",   cmd: 183, p1: 4, p2: lo, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: commandGapSeconds },
                    { label: "V-tail Mix -> Center S2",           cmd: 183, p1: 2, p2: center, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: shortGap },
                    { label: "V-tail Mix -> Center S4",           cmd: 183, p1: 4, p2: center, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: commandGapSeconds },

                    // V-tail yaw right: SERVO2 high, SERVO4 low
                    { label: "V-tail Mix -> Yaw Right S2 High",   cmd: 183, p1: 2, p2: hi, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: shortGap },
                    { label: "V-tail Mix -> Yaw Right S4 Low",    cmd: 183, p1: 4, p2: lo, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: commandGapSeconds },
                    { label: "V-tail Mix -> Center S2",           cmd: 183, p1: 2, p2: center, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: shortGap },
                    { label: "V-tail Mix -> Center S4",           cmd: 183, p1: 4, p2: center, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: commandGapSeconds },

                    // V-tail yaw left: SERVO2 low, SERVO4 high
                    { label: "V-tail Mix -> Yaw Left S2 Low",     cmd: 183, p1: 2, p2: lo, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: shortGap },
                    { label: "V-tail Mix -> Yaw Left S4 High",    cmd: 183, p1: 4, p2: hi, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: commandGapSeconds },
                    { label: "V-tail Mix -> Center S2",           cmd: 183, p1: 2, p2: center, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: shortGap },
                    { label: "V-tail Mix -> Center S4",           cmd: 183, p1: 4, p2: center, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: commandGapSeconds }
                ]
            }

            function buildLiftMotorCommands() {
                var waitEach = motorTestDuration + commandGapSeconds

                return [
                    { label: "Lift Motor 1", cmd: 209, p1: 1, p2: 0, p3: liftMotorThrottle, p4: motorTestDuration, p5: 1, p6: 0, p7: 0, waitSeconds: waitEach },
                    { label: "Lift Motor 2", cmd: 209, p1: 2, p2: 0, p3: liftMotorThrottle, p4: motorTestDuration, p5: 1, p6: 0, p7: 0, waitSeconds: waitEach },
                    { label: "Lift Motor 3", cmd: 209, p1: 3, p2: 0, p3: liftMotorThrottle, p4: motorTestDuration, p5: 1, p6: 0, p7: 0, waitSeconds: waitEach },
                    { label: "Lift Motor 4", cmd: 209, p1: 4, p2: 0, p3: liftMotorThrottle, p4: motorTestDuration, p5: 1, p6: 0, p7: 0, waitSeconds: waitEach }
                ]
            }

            function shouldLockForFlight() {
                // Flying thật thì luôn khóa.
                if (vehicleFlyingSafe()) {
                    return true
                }

                // ArduPilot có thể báo armed tạm trong lúc MOTOR_TEST.
                // Trong khoảng grace này, coi là preflight motor test, không phải bay thật.
                var nowMs = new Date().getTime()
                if (vehicleArmedSafe() && commandRunning && nowMs < motorTestArmGraceUntil) {
                    return false
                }

                // ARM ngoài cửa sổ motor test thì khóa.
                if (vehicleArmedSafe()) {
                    return true
                }

                return false
            }

            function lockForFlight() {
                restoreVtolDirectOutputTest()
                commandSequenceTimer.stop()
                commandQueue = []
                commandIndex = 0
                commandRunning = false
                commandPaused = false
                gremsyMotorTestActive = false
                commandProgressRatio = 0.0
                commandProgressText = "Gremsy Ready đã khóa vì máy bay đã ARM/Flying."

                safetyConfirmed = false
                waitingUserConfirm = false
                testFailed = true
                finalStatusText = "GREMSY READY: LOCKED / NOT READY"

                appendCommandLog("LOCKED: Vehicle armed/flying, command queue stopped.")
                resultText.text = "Gremsy Ready đã dừng queue vì máy bay ARM/Flying. Không gửi Push Motor/Servo hoặc lệnh test tiếp theo."
            }

            function guardTest(testName) {
                if (!vehicleConnected) {
                    resultText.text = testName + ": Chưa nhận máy bay."
                    return false
                }

                if (vehicleArmed) {
                    resultText.text = testName + ": Không thể test vì máy bay đã ARM."
                    return false
                }

                if (!safetyConfirmed) {
                    resultText.text = testName + ": Vui lòng xác nhận đã tháo cánh/quạt."
                    return false
                }

                return true
            }

            function emergencyStop() {
                commandSequenceTimer.stop()
                commandQueue = []
                commandIndex = 0
                commandRunning = false
                commandPaused = false
                commandProgressText = "ĐÃ DỪNG KHẨN CẤP"
                commandProgressRatio = 0.0

                testFailed = true
                waitingUserConfirm = false
                motorPass = false
                servoPass = false
                fullPass = false
                finalStatusText = "GREMSY READY: STOPPED / NOT READY"

                // Cố gắng đưa các output về trạng thái an toàn.
                // Push motor về idle, servo về center.
                sendSetServo(3, 1000)
                sendSetServo(1, 1500)
                sendSetServo(2, 1500)
                sendSetServo(4, 1500)
                sendSetServo(9, 1500)

                // Với lift motor đang chạy bằng MAV_CMD_DO_MOTOR_TEST,
                // gửi yêu cầu test 0% trong 1s cho motor 1-4.
                sendCommand(209, 1, 0, 0, 1, 1, 0, 0)
                sendCommand(209, 2, 0, 0, 1, 1, 0, 0)
                sendCommand(209, 3, 0, 0, 1, 1, 0, 0)
                sendCommand(209, 4, 0, 0, 1, 1, 0, 0)

                resultText.text = "ĐÃ DỪNG KHẨN CẤP. Nếu motor vẫn quay bất thường, ngắt nguồn ngay."
            }

            function markTestPass() {
                if (!waitingUserConfirm) {
                    resultText.text = "Chỉ xác nhận PASS sau khi test chạy xong."
                    return
                }

                testFailed = false
                waitingUserConfirm = false
                motorPass = true
                servoPass = true
                fullPass = true
                lastResult = "PASS"
                finalStatusText = "GREMSY READY: TEST PASSED"
                resultText.text = "Người test đã xác nhận PASS. Máy bay sẵn sàng qua bước Gremsy Ready."
                updateCsvPreview()
                saveCsvRecord()
            }

            function markTestFail() {
                testFailed = true
                waitingUserConfirm = false
                motorPass = false
                servoPass = false
                fullPass = false
                lastResult = "FAIL"
                finalStatusText = "GREMSY READY: TEST FAILED / NOT READY"
                resultText.text = "Người test đã xác nhận FAIL. Không sẵn sàng bay. Cần kiểm tra lại."
                updateCsvPreview()
                saveCsvRecord()
            }

            function csvEscape(value) {
                var s = String(value)
                s = s.replace(/"/g, '""')
                return '"' + s + '"'
            }

            function updateCsvPreview() {
                var timestamp = Qt.formatDateTime(new Date(), "yyyy-MM-dd hh:mm:ss")
                var vehicleName = detectedDroneType()

                csvPreview =
                    csvEscape(timestamp) + "," +
                    csvEscape(testerName) + "," +
                    csvEscape(testDate) + "," +
                    csvEscape(vehicleName) + "," +
                    csvEscape(vtolTestCount) + "," +
                    csvEscape(lastResult) + "," +
                    csvEscape(liftMotorThrottle) + "," +
                    csvEscape(motorTestDuration) + "," +
                    csvEscape(pushMotorPwm) + "," +
                    csvEscape(servoDelta) + "," +
                    csvEscape(commandGapSeconds) + "," +
                    csvEscape(csvTestNote())
            }

            function appendCommandLog(message) {
                var timestamp = Qt.formatDateTime(new Date(), "hh:mm:ss")
                var lines = commandLog.length > 0 ? commandLog.split("\n") : []
                lines.push(timestamp + "  " + message)

                while (lines.length > 3) {
                    lines.shift()
                }

                commandLog = lines.join("\n")
            }

            function saveCsvRecord() {
                if (csvPreview.length === 0) {
                    updateCsvPreview()
                }

                csvSaveStatus = QGroundControl.appendGremsyReadyCsvLine(csvPreview)
                resultText.text = resultText.text + " | " + csvSaveStatus
            }

            function sendCommand(command, p1, p2, p3, p4, p5, p6, p7) {
                if (!activeVehicle) {
                    resultText.text = "Chưa nhận máy bay."
                    return
                }

                if (shouldLockForFlight()) {
                    lockForFlight()
                    return
                }

                // MAV_COMP_ID_AUTOPILOT1 = 1
                // Không dùng defaultComponentId vì có thể ra MAV_COMP_ID_ALL = 0
                activeVehicle.sendMavCommand(
                    1,
                    command,
                    false,
                    p1, p2, p3, p4, p5, p6, p7
                )
            }

            function sendMotorTest(motorNumber) {
                // MAV_CMD_DO_MOTOR_TEST = 209
                // param1: motor number
                // param2: throttle type, 0 = percent
                // param3: throttle value
                // param4: duration seconds
                // param5: motor count
                // param6: test order
                sendCommand(209, motorNumber, 0, liftMotorThrottle, motorTestDuration, 1, 0, 0)
            }

            function sendSetServo(servoNumber, pwm) {
                // MAV_CMD_DO_SET_SERVO = 183
                // param1: servo output number
                // param2: PWM us
                sendCommand(183, servoNumber, pwm, 0, 0, 0, 0, 0)
            }

            function runMotorMavlinkTest() {
                var cmds = buildLiftMotorCommands()
                startCommandQueue(cmds, "Motor Test: " + detectedDroneType() + " profile - test lần lượt 4 lift motor.")
            }

            function runServoMavlinkTest() {
                if (!isQuadPlaneProfile()) {
                    resultText.text = "Servo Test chỉ dùng cho VTOL / QuadPlane. Vehicle hiện tại: " + detectedDroneType()
                    appendCommandLog("BLOCKED: Servo Test only for VTOL / QuadPlane. Current=" + detectedDroneType())
                    return
                }

                currentTestRequiresManualVtolVerify = false
                manualVtolVerifyText = ""

                var directOk = prepareVtolDirectOutputTest()

                if (!directOk) {
                    resultText.text = "Không thể bật Direct Output Test. SERVO_FUNCTION chưa chuyển về 0."
                    appendCommandLog("ABORT SERVO TEST: Direct output prepare failed.")
                    return
                }

                var cmds = buildVtolPushServoDirectCommands()
                startCommandQueue(cmds, "Servo/Push Test: QUADPLANE direct output test.")
            }

            function runPushMotorMavlinkTest() {
                if (!isQuadPlaneProfile()) {
                    resultText.text = "Push Motor Test chỉ dùng cho VTOL / QuadPlane. Vehicle hiện tại: " + detectedDroneType()
                    appendCommandLog("BLOCKED: Push Motor Test only for VTOL / QuadPlane. Current=" + detectedDroneType())
                    return
                }

                currentTestRequiresManualVtolVerify = false
                manualVtolVerifyText = ""

                var directOk = prepareVtolDirectOutputTest()

                if (!directOk) {
                    resultText.text = "Không thể bật Direct Output Test. SERVO3_FUNCTION chưa chuyển về 0."
                    appendCommandLog("ABORT PUSH TEST: Direct output prepare failed.")
                    return
                }

                var cmds = [
                    { label: "Push SERVO3 -> PWM",  cmd: 183, p1: 3, p2: pushMotorPwm, p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: commandGapSeconds },
                    { label: "Push SERVO3 -> Idle", cmd: 183, p1: 3, p2: 1000,         p3: 0, p4: 0, p5: 0, p6: 0, p7: 0, waitSeconds: commandGapSeconds }
                ]

                startCommandQueue(cmds, "Push Motor Test: SERVO3 direct output test.")
            }

            function runFullMavlinkTest() {
                var cmds = buildLiftMotorCommands()

                if (isQuadPlaneProfile()) {
                    currentTestRequiresManualVtolVerify = false
                    manualVtolVerifyText = ""

                    var directOk = prepareVtolDirectOutputTest()

                    if (!directOk) {
                        resultText.text = "Không thể bật Direct Output Test. SERVO_FUNCTION chưa chuyển về 0, không gửi Push/Servo để tránh sai lệch."
                        appendCommandLog("ABORT PUSH/SERVO: Direct output prepare failed.")
                        return
                    }

                    cmds = cmds.concat(buildVtolPushServoDirectCommands())

                    startCommandQueue(
                        cmds,
                        "Full Test: QUADPLANE profile - Lift Motor + Direct Push Motor/Servo test."
                    )
                } else {
                    currentTestRequiresManualVtolVerify = false
                    manualVtolVerifyText = ""

                    startCommandQueue(
                        cmds,
                        "Full Test: QUADCOPTER profile - Auto test 4 lift motor."
                    )
                }
            }


            Timer {
                id: gremsyReadyFlightLockTimer
                interval: 250
                repeat: true
                running: true
                onTriggered: {
                    if (gremsyReadyPanel.shouldLockForFlight() &&
                        (gremsyReadyPanel.commandRunning ||
                         gremsyReadyPanel.commandPaused ||
                         gremsyReadyPanel.safetyConfirmed)) {
                        gremsyReadyPanel.lockForFlight()
                    }
                }
            }

            Timer {
                id: commandSequenceTimer
                interval: Math.max(500, gremsyReadyPanel.currentWaitSeconds * 1000)
                repeat: true
                onTriggered: gremsyReadyPanel.sendNextQueuedCommand()
            }

            Timer {
                id: pushMotorReturnTimer
                interval: 1500
                repeat: false
                onTriggered: {
                    gremsyReadyPanel.sendSetServo(3, 1000)
                }
            }

            Timer {
                id: servoReturnTimer
                interval: 1200
                repeat: false
                onTriggered: {
                    gremsyReadyPanel.sendSetServo(1, 1500)
                    gremsyReadyPanel.sendSetServo(2, 1500)
                    gremsyReadyPanel.sendSetServo(4, 1500)
                    gremsyReadyPanel.sendSetServo(9, 1500)
                }
            }

            Column {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 10

                Text {
                    text: "Gremsy Ready - VTOL Preflight Test"
                    color: "white"
                    font.pixelSize: 24
                    font.bold: true
                }

                Text {
                    text: !gremsyReadyPanel.vehicleConnected ?
                          "Trạng thái: Chưa nhận máy bay" :
                          gremsyReadyPanel.vehicleArmed ?
                          "Trạng thái: Đã ARM - Gremsy Ready bị khóa" :
                          "Trạng thái: Đã nhận máy bay - Sẵn sàng Pre-flight"
                    color: gremsyReadyPanel.readyAllowed ? "#00AEEF" : "#FFCC00"
                    font.pixelSize: 16
                    font.bold: true
                }

                Text {
                    text: "Cảnh báo: Tháo cánh/quạt và đảm bảo khu vực an toàn trước khi test motor/servo."
                    color: "#FFCC00"
                    font.pixelSize: 15
                }

                Rectangle {
                    width: parent.width
                    height: 92
                    radius: 6
                    color: "#0D1D23"
                    border.color: "#30505A"
                    border.width: 1

                    Column {
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 8

                        Row {
                            spacing: 12

                            Text {
                                text: "Người test"
                                color: "white"
                                font.pixelSize: 14
                                width: 90
                            }

                            TextField {
                                width: 180
                                height: 32
                                text: gremsyReadyPanel.testerName
                                placeholderText: "Nhập tên"
                                enabled: !gremsyReadyPanel.commandRunning
                                onTextChanged: gremsyReadyPanel.testerName = text
                            }

                            Text {
                                text: "Ngày test"
                                color: "white"
                                font.pixelSize: 14
                                width: 80
                            }

                            TextField {
                                width: 120
                                height: 32
                                text: gremsyReadyPanel.testDate
                                enabled: !gremsyReadyPanel.commandRunning
                                onTextChanged: gremsyReadyPanel.testDate = text
                            }

                            Text {
                                text: gremsyReadyPanel.testNoLabelText()
                                color: "white"
                                font.pixelSize: 14
                                width: 100
                            }

                            QGCButton {
                                text: "-"
                                width: 38
                                enabled: !gremsyReadyPanel.commandRunning
                                onClicked: gremsyReadyPanel.vtolTestCount = Math.max(1, gremsyReadyPanel.vtolTestCount - 1)
                            }

                            Text {
                                text: gremsyReadyPanel.vtolTestCount
                                color: "#00AEEF"
                                font.pixelSize: 14
                                width: 40
                                horizontalAlignment: Text.AlignHCenter
                            }

                            QGCButton {
                                text: "+"
                                width: 38
                                enabled: !gremsyReadyPanel.commandRunning
                                onClicked: gremsyReadyPanel.vtolTestCount = gremsyReadyPanel.vtolTestCount + 1
                            }
                        }

                        Row {
                            spacing: 12

                            Text {
                                text: "Ghi chú"
                                color: "white"
                                font.pixelSize: 14
                                width: 90
                            }

                            TextField {
                                width: 600
                                height: 32
                                text: gremsyReadyPanel.testNote
                                placeholderText: "Ví dụ: motor 1 hơi rung, servo OK..."
                                enabled: !gremsyReadyPanel.commandRunning
                                onTextChanged: gremsyReadyPanel.testNote = text
                            }
                        }
                    }
                }

                Row {
                    spacing: 12

                    QGCButton {
                        text: gremsyReadyPanel.safetyConfirmed ? "✓ Đã xác nhận an toàn" : "Xác nhận tháo cánh/quạt"
                        width: 230
                        enabled: !gremsyReadyPanel.vehicleArmed
                        onClicked: {
                            gremsyReadyPanel.safetyConfirmed = !gremsyReadyPanel.safetyConfirmed
                        }
                    }

                    Text {
                        text: gremsyReadyPanel.vehicleArmed ?
                              "Máy bay đã ARM, không cho phép test." :
                              "Bắt buộc xác nhận trước khi chạy test motor/servo."
                        color: gremsyReadyPanel.vehicleArmed ? "#FF5252" : "white"
                        font.pixelSize: 15
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Grid {
                    columns: 2
                    columnSpacing: 36
                    rowSpacing: 8

                    Row {
                        id: gremsyProfileSelectorSimple
                        spacing: 8

                        Text {
                            text: "Test Profile:"
                            color: "white"
                            font.pixelSize: 14
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Button {
                            text: "Auto"
                            enabled: !gremsyReadyPanel.commandRunning
                            onClicked: gremsyReadyPanel.setTestProfileOverride("AUTO")
                        }

                        Button {
                            text: "Quadcopter"
                            enabled: !gremsyReadyPanel.commandRunning
                            onClicked: gremsyReadyPanel.setTestProfileOverride("QUADCOPTER")
                        }

                        Button {
                            text: "VTOL / QuadPlane"
                            enabled: !gremsyReadyPanel.commandRunning
                            onClicked: gremsyReadyPanel.setTestProfileOverride("QUADPLANE")
                        }

                        Text {
                            text: "Đang dùng: " + gremsyReadyPanel.profileDisplayText()
                            color: "#00AEEF"
                            font.pixelSize: 14
                            font.bold: true
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    Row {
                        spacing: 10
                        Text { text: "Lift Motor"; color: "white"; font.pixelSize: 15; width: 110 }
                        QGCButton { text: "-"; width: 38; onClicked: gremsyReadyPanel.liftMotorThrottle = Math.max(5, gremsyReadyPanel.liftMotorThrottle - 1) }
                        Text { text: gremsyReadyPanel.liftMotorThrottle + " %"; color: "#00AEEF"; font.pixelSize: 15; width: 70; horizontalAlignment: Text.AlignHCenter }
                        QGCButton { text: "+"; width: 38; onClicked: gremsyReadyPanel.liftMotorThrottle = Math.min(15, gremsyReadyPanel.liftMotorThrottle + 1) }
                    }

                    Row {
                        spacing: 10
                        Text { text: "Duration"; color: "white"; font.pixelSize: 15; width: 110 }
                        QGCButton { text: "-"; width: 38; onClicked: gremsyReadyPanel.motorTestDuration = Math.max(1, gremsyReadyPanel.motorTestDuration - 1) }
                        Text { text: gremsyReadyPanel.motorTestDuration + " s"; color: "#00AEEF"; font.pixelSize: 15; width: 70; horizontalAlignment: Text.AlignHCenter }
                        QGCButton { text: "+"; width: 38; onClicked: gremsyReadyPanel.motorTestDuration = Math.min(5, gremsyReadyPanel.motorTestDuration + 1) }
                    }

                    Row {
                        spacing: 10
                        Text { text: "Push PWM"; color: "white"; font.pixelSize: 15; width: 110 }
                        QGCButton { text: "-"; width: 38; onClicked: gremsyReadyPanel.pushMotorPwm = Math.max(1050, gremsyReadyPanel.pushMotorPwm - 10) }
                        Text { text: gremsyReadyPanel.pushMotorPwm + " us"; color: "#00AEEF"; font.pixelSize: 15; width: 90; horizontalAlignment: Text.AlignHCenter }
                        QGCButton { text: "+"; width: 38; onClicked: gremsyReadyPanel.pushMotorPwm = Math.min(1200, gremsyReadyPanel.pushMotorPwm + 10) }
                    }

                    Row {
                        spacing: 10
                        Text { text: "Servo Delta"; color: "white"; font.pixelSize: 15; width: 110 }
                        QGCButton { text: "-"; width: 38; onClicked: gremsyReadyPanel.servoDelta = Math.max(100, gremsyReadyPanel.servoDelta - 25) }
                        Text { text: "+/- " + gremsyReadyPanel.servoDelta + " us"; color: "#00AEEF"; font.pixelSize: 15; width: 100; horizontalAlignment: Text.AlignHCenter }
                        QGCButton { text: "+"; width: 38; onClicked: gremsyReadyPanel.servoDelta = Math.min(300, gremsyReadyPanel.servoDelta + 25) }
                    }
                }

                Row {
                    spacing: 10

                    Text {
                        text: "Command Gap"
                        color: "white"
                        font.pixelSize: 15
                        width: 110
                    }

                    QGCButton {
                        text: "-"
                        width: 38
                        enabled: !gremsyReadyPanel.commandRunning
                        onClicked: gremsyReadyPanel.commandGapSeconds = Math.max(1, gremsyReadyPanel.commandGapSeconds - 1)
                    }

                    Text {
                        text: gremsyReadyPanel.commandGapSeconds + " s"
                        color: "#00AEEF"
                        font.pixelSize: 15
                        width: 70
                        horizontalAlignment: Text.AlignHCenter
                    }

                    QGCButton {
                        text: "+"
                        width: 38
                        enabled: !gremsyReadyPanel.commandRunning
                        onClicked: gremsyReadyPanel.commandGapSeconds = Math.min(10, gremsyReadyPanel.commandGapSeconds + 1)
                    }

                    Text {
                        text: "Khuyến nghị: SITL 1-2s, máy bay thật 5-10s."
                        color: "white"
                        font.pixelSize: 14
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Row {
                    spacing: 12

                    QGCButton {
                        text: "Run Motor Test"
                        enabled: gremsyReadyPanel.readyAllowed && !gremsyReadyPanel.commandRunning
                        onClicked: {
                            if (gremsyReadyPanel.guardTest("Motor Test")) {
                                gremsyReadyPanel.motorPass = true
                                gremsyReadyPanel.runMotorMavlinkTest()
                                resultText.text = "Motor Test: Đã gửi MAVLink MOTOR_TEST cho motor nâng 1-4, " + gremsyReadyPanel.liftMotorThrottle + "% trong " + gremsyReadyPanel.motorTestDuration + "s."
                            }
                        }
                    }

                    QGCButton {
                        text: "Run Servo Test"
                        enabled: gremsyReadyPanel.readyAllowed && !gremsyReadyPanel.commandRunning
                        onClicked: {
                            if (gremsyReadyPanel.guardTest("Servo Test")) {
                                gremsyReadyPanel.servoPass = true
                                gremsyReadyPanel.runServoMavlinkTest()
                                resultText.text = "Servo Test: Đã đưa SET_SERVO vào hàng đợi tuần tự cho servo 1,2,4,9."
                            }
                        }
                    }

                    QGCButton {
                        text: "Run Full Test"
                        enabled: gremsyReadyPanel.readyAllowed && !gremsyReadyPanel.commandRunning
                        onClicked: {
                            if (gremsyReadyPanel.guardTest("Full Test")) {
                                gremsyReadyPanel.motorPass = true
                                gremsyReadyPanel.servoPass = true
                                gremsyReadyPanel.fullPass = true
                                gremsyReadyPanel.runFullMavlinkTest()
                            }
                        }
                    }

                    QGCButton {
                        text: gremsyReadyPanel.commandPaused ? "Continue" : "Pause"
                        enabled: gremsyReadyPanel.commandRunning
                        onClicked: {
                            if (gremsyReadyPanel.commandPaused) {
                                gremsyReadyPanel.continueTest()
                            } else {
                                gremsyReadyPanel.pauseTest()
                            }
                        }
                    }

                    QGCButton {
                        text: "Reset Test"
                        enabled: !gremsyReadyPanel.commandRunning || gremsyReadyPanel.commandPaused
                        onClicked: gremsyReadyPanel.resetResult()
                    }
                }

                Text {
                    id: resultText
                    text: !gremsyReadyPanel.vehicleConnected ?
                          "Chưa nhận máy bay. Vui lòng kết nối trước khi chạy test." :
                          gremsyReadyPanel.vehicleArmed ?
                          "Máy bay đã ARM. Gremsy Ready bị khóa." :
                          gremsyReadyPanel.safetyConfirmed ?
                          "Đã nhận máy bay và đã xác nhận an toàn. Có thể chạy test UI." :
                          "Đã nhận máy bay. Vui lòng xác nhận tháo cánh/quạt trước khi test."
                    color: "white"
                    font.pixelSize: 15
                    width: parent.width
                    wrapMode: Text.WordWrap
                }

                Text {
                    text: gremsyReadyPanel.commandProgressText
                    color: gremsyReadyPanel.commandRunning ? "#00AEEF" : "white"
                    font.pixelSize: 14
                    width: parent.width
                    wrapMode: Text.WordWrap
                }

                Rectangle {
                    id: gremsyProgressBarBg
                    width: parent.width
                    height: 10
                    radius: 5
                    color: "#333333"

                    Rectangle {
                        id: gremsyProgressBar
                        width: parent.width * gremsyReadyPanel.commandProgressRatio
                        height: parent.height
                        radius: 5
                        color: "#00AEEF"
                    }
                }

                Rectangle {
                    id: gremsyCommandLogBox
                    clip: true
                    width: parent.width
                    height: 70
                    radius: 6
                    color: "#101820"
                    border.color: "#30505A"
                    border.width: 1
                    visible: gremsyReadyPanel.commandLog.length > 0

                    Column {
                        anchors.fill: parent
                        anchors.margins: 8
                        spacing: 4

                        Text {
                            text: "Command Log"
                            color: "#00AEEF"
                            font.pixelSize: 13
                            font.bold: true
                        }

                        Text {
                            text: gremsyReadyPanel.commandLog
                            color: "white"
                            font.pixelSize: 12
                            width: parent.width
                            wrapMode: Text.WordWrap
                        }
                    }
                }

                Rectangle {
                    id: gremsyPwmVerifyBox
                    width: parent.width
                    height: 86
                    radius: 6
                    color: "#101820"
                    border.color: "#30505A"
                    border.width: 1
                    visible: gremsyReadyPanel.isQuadPlaneProfile() && gremsyReadyPanel.pwmVerifyActive

                    Column {
                        anchors.fill: parent
                        anchors.margins: 8
                        spacing: 4

                        Text {
                            text: gremsyReadyPanel.pwmVerifyOverallText()
                            color: "#00AEEF"
                            font.pixelSize: 13
                            font.bold: true
                        }

                        Text {
                            text: gremsyReadyPanel.pwmCheckText(3, "SERVO3 Push") + "    " +
                                  gremsyReadyPanel.pwmCheckText(1, "SERVO1 Ail") + "    " +
                                  gremsyReadyPanel.pwmCheckText(9, "SERVO9 Ail")
                            color: "white"
                            font.pixelSize: 12
                        }

                        Text {
                            text: gremsyReadyPanel.pwmCheckText(2, "SERVO2 Vtail L") + "    " +
                                  gremsyReadyPanel.pwmCheckText(4, "SERVO4 Vtail R")
                            color: "white"
                            font.pixelSize: 12
                        }
                    }
                }

                Row {
                    id: gremsyPassFailRow
                    spacing: 12
                    visible: gremsyReadyPanel.waitingUserConfirm || gremsyReadyPanel.testFailed || gremsyReadyPanel.fullPass

                    QGCButton {
                        text: "Xác nhận PASS"
                        enabled: gremsyReadyPanel.waitingUserConfirm && !gremsyReadyPanel.commandRunning
                        onClicked: gremsyReadyPanel.markTestPass()
                    }

                    QGCButton {
                        text: "Báo FAIL / Không sẵn sàng"
                        enabled: !gremsyReadyPanel.commandRunning
                        onClicked: gremsyReadyPanel.markTestFail()
                    }

                    Text {
                        text: gremsyReadyPanel.waitingUserConfirm ?
                              "PASS nếu đạt, FAIL nếu bất thường." :
                              gremsyReadyPanel.testFailed ?
                              "Kết quả: FAIL / NOT READY" :
                              "Kết quả: PASS"
                        color: gremsyReadyPanel.testFailed ? "#FF5252" : "#00E676"
                        font.pixelSize: 15
                        font.bold: true
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Rectangle {
                    width: parent.width
                    height: gremsyReadyPanel.csvPreview.length > 0 ? 64 : 0
                    visible: false
                    radius: 6
                    color: "#111111"
                    border.color: "#30505A"
                    border.width: 1

                    Column {
                        anchors.fill: parent
                        anchors.margins: 8
                        spacing: 4

                        Text {
                            text: "CSV Preview:"
                            color: "#00AEEF"
                            font.pixelSize: 13
                            font.bold: true
                        }

                        Text {
                            text: gremsyReadyPanel.csvPreview
                            color: "white"
                            font.pixelSize: 12
                            width: parent.width
                            elide: Text.ElideRight
                        }
                    }
                }

                Text {
                    id: gremsyCsvSaveStatusText
                    text: gremsyReadyPanel.csvSaveStatus
                    visible: false
                    color: gremsyReadyPanel.csvSaveStatus.indexOf("failed") >= 0 ? "#FF5252" : "#00E676"
                    font.pixelSize: 13
                    width: parent.width
                    wrapMode: Text.WordWrap
                }

                Rectangle {
                    width: parent.width
                    height: 34
                    radius: 6
                    color: gremsyReadyPanel.testFailed ?
                           "#B00020" :
                           (gremsyReadyPanel.motorPass && gremsyReadyPanel.servoPass && gremsyReadyPanel.fullPass) ?
                           "#00AEEF" :
                           gremsyReadyPanel.waitingUserConfirm ?
                           "#FF9800" :
                           "#555555"

                    Text {
                        anchors.centerIn: parent
                        text: gremsyReadyPanel.finalStatusText
                        color: "white"
                        font.pixelSize: 15
                        font.bold: true
                    }
                }
            }
        }

        Text {
            id: checklistTitle
            text: qsTr("Checklist gốc QGroundControl")
            color: "white"
            font.pixelSize: 20
            font.bold: true
        }

        Rectangle {
            id: separator
            width: parent.width
            height: 1
            color: "#00AEEF"
            opacity: 0.7
        }

        Loader {
            id: checkList
            width: parent.width
            source: QGroundControl.corePlugin.options.preFlightChecklistUrl
        }
    }
}

    property alias checkListItem: checkList.item

    Connections {
        target: checkList.item
        onAllChecksPassedChanged: {
            if (target.allChecksPassed) {
                popupTimer.restart()
            }
        }
    }
}
