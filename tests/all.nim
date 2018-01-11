import unittest, os, base64, json, mqtt, nuuid

import messenger

const blinkySrc = readFile("blinky.ino")

startMessenger("tcp://localhost:1883", "test", "test", "itsme")

suite "Testing verify via MQTT":  
  test "Verify blinky":
    # Submit trivial blinky
    # Generate an id for the response we want to get
    let responseId = generateUUID()
    # Subscribe in advance for that response
    subscribeMQTT("response/verify/" & responseId, QOS0)
    # Construct a job to run
    var json = %*{
      "sketch": "blinky.ino",
      "src": encode(blinkySrc)
    }
    # Submit it as a verify job
    publishMQTT("verify/" & responseId, $json)
    # Make sure we got a response
    var msg = popMessage()
    check(msg.topic == "response/verify/" & responseId)
    var jobId = parseJson(msg.payload)["id"].getStr
    # Make sure we got a result with exitCode 0
    subscribeMQTT("result/" & jobId, QOS0)
    msg = popMessage()
    check(msg.topic == "result/" & jobId)
    var result = parseJson(msg.payload)
    check(result["type"].getStr == "success")
    check(result["exitCode"].getNum == 0)
    
  test "Upload blinky":
    # Submit trivial blinky
    # Generate an id for the response we want to get
    let responseId = generateUUID()
    # Subscribe in advance for that response
    subscribeMQTT("response/upload/" & responseId, QOS0)
    # Construct a job to run
    var json = %*{
      "sketch": "blinky.ino",
      "src": encode(blinkySrc)
    }
    # Submit it as an upload job
    publishMQTT("upload/" & responseId, $json)
    # Make sure we got a response
    var msg = popMessage()
    check(msg.topic == "response/upload/" & responseId)
    var jobId = parseJson(msg.payload)["id"].getStr
    # Make sure we got a result
    subscribeMQTT("result/" & jobId, QOS0)
    msg = popMessage()
    check(msg.topic == "result/" & jobId)
    var result = parseJson(msg.payload)
    check(result["type"].getStr == "success")
    check(result["exitCode"].getNum == 0)
 