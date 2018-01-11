# Arduinobot is a service written in Nim, run as:
#
#   arduinobot -u myuser -p mysecretpassword -s tcp://some-mqtt-server.com:1883
#
# Arduinobot listens on port 80 for REST calls with JSON payloads
# and on corresponding MQTT topics listed below.
#
# * Jester runs in the main thread, asynchronously. 
# * MQTT is handled in the messengerThread and uses one Channel to publish, and another to get messages.
# * Jobs are spawned on the threadpool and results are published on MQTT via the messenger Channel.
#
# Topics used:
#
# verify/<response-id>             - Payload is JSON specification for a job.
# upload/<response-id>             - Payload is JSON specification for a job.
# response/<command>/<response-id> - Responses to requests are published here as JSON, typically with job id.
# result/<job-id>                  - Results from Jobs are published here as JSON.
#
# Jobs are built today using Arduino via command line, as described here:
#   https://github.com/arduino/Arduino/blob/master/build/shared/manpage.adoc

import jester, asyncdispatch, mqtt, MQTTClient, asyncnet, htmlgen, json, logging, os, strutils,
  sequtils, nuuid, tables, osproc, base64, threadpool, docopt, streams, pegs

# Jester settings
settings:
  port = Port(8080)

# Various defaults
const
  # TODO Obviously should not be const
  arduinoBoard = "arduino:avr:uno"
  arduinoPort = "/dev/ttyACM0"
  arduinoResultFile = "arduinobot-result.json"
  arduinobotVersion = "arduinobot 0.1.0"

template buildsDirectory: string = getCurrentDir() / "builds"

let help = """
  arduinobot
  
  Usage:
    arduinobot [-c CONFIGFILE] [-a PATH] [-u USERNAME] [-p PASSWORD] [-s MQTTURL]
    arduinobot (-h | --help)
    arduinobot (-v | --version)

  Options:
    -u USERNAME       Set MQTT username [default: test].
    -p PASSWORD       Set MQTT password [default: test].
    -s MQTTURL        Set URL for the MQTT server [default: tcp://localhost:1883]
    -a PATH           Set full path to Arduino IDE executable [default: ~/arduino-1.8.4/arduino]
    -c CONFIGFILE     Load options from given filename if it exists [default: arduinobot.conf]
    -h --help         Show this screen.
    -v --version      Show version.
  """

var args = docopt(help, version = arduinobotVersion)

# Pool size
setMinPoolSize(50)
setMaxPoolSize(50)

# We need to load config file if it exists and run docopt again
let config = $args["-c"]
if existsFile(getCurrentDir() / config):
  var conf = readFile(getCurrentDir() / config).splitWhitespace()
  var params = commandLineParams().concat(conf)
  args = docopt(help, params, version = arduinobotVersion)

# MQTT parameters
let clientID = "arduinobot-" & generateUUID()
let username = $args["-u"]
let password = $args["-p"]
let serverUrl = $args["-s"]

# Local thread config variable
var arduinoIde {.threadvar.}: string

type
  MessageKind = enum connect, configure, publish, stop
  Message = object
    case kind: MessageKind
    of connect:
      serverUrl, clientID, username, password: string
    of configure:
      arduinoIde: string
    of publish:
      topic, payload: string
    of stop:
      nil

var
  messengerThread: Thread[void]
  channel: Channel[Message]

proc publishMQTT*(topic, payload: string) =
  channel.send(Message(kind: publish, topic: topic, payload: payload))

proc connectMQTT*(s, c, u, p: string) =
  channel.send(Message(kind: connect, serverUrl: s, clientID: c, username: u, password: p))

proc configureMessenger*(arduinoIde: string) =
  channel.send(Message(kind: configure, arduinoIde: arduinoIde))
    
proc stopMessenger() {.noconv.} =
  channel.send(Message(kind: stop))
  joinThread(messengerThread)
  close(channel)
  
proc connectToServer(serverUrl, clientID, username, password: string): MQTTClient =
  try:
    echo "Connecting as " & clientID & " to " & serverUrl
    result = newClient(serverUrl, clientID, MQTTPersistenceType.None)
    var connectOptions = newConnectOptions()
    connectOptions.username = username
    connectOptions.password = password
    result.connect(connectOptions)
    result.subscribe("config", QOS0)
    result.subscribe("verify/+", QOS0)
    result.subscribe("upload/+", QOS0)
  except MQTTError:
    quit "MQTT exception: " & getCurrentExceptionMsg()

proc startVerifyJob(spec: JsonNode): JsonNode {.gcsafe.}
proc handleVerify(responseId, payload: string) =
  var spec: JsonNode
  try:
    spec = parseJson(payload)
    let job = startVerifyJob(spec)
    publishMQTT("response/verify/" & responseId, $job)
  except:
    stderr.writeLine "Unable to parse JSON body: " & payload
    
proc startUploadJob(spec: JsonNode): JsonNode {.gcsafe.}
proc handleUpload(responseId, payload: string) =
  var spec: JsonNode
  try:
    spec = parseJson(payload)
    let job = startUploadJob(spec)
    publishMQTT("response/upload/" & responseId, $job)
  except:
    stderr.writeLine "Unable to parse JSON body: " & payload

proc handleMessage(topic: string, message: MQTTMessage) =
  var parts = topic.split('/')
  if parts.len == 2:
    case parts[0]
    of "verify":
      handleVerify(parts[1], message.payload)
    of "upload":
      handleUpload(parts[1], message.payload)
    else:
      stderr.writeLine "Unknown topic: " & topic

proc messengerLoop() {.thread.} =
  var client: MQTTClient
  while true:
    if client.isConnected:
      var topicName: string
      var message: MQTTMessage
      # Wait upto 100 ms to receive an MQTT message
      let timeout = client.receive(topicName, message, 100)
      if not timeout:
        #echo "Topic: " & topicName & " payload: " & message.payload
        handleMessage(topicName, message)
    # If we have something in the channel, handle it
    var (gotit, msg) = tryRecv(channel)
    if gotit:
      case msg.kind
      of connect:
        client = connectToServer(msg.serverUrl, msg.clientID, msg.username, msg.password)
      of configure:
        arduinoIde = msg.arduinoIde
      of publish:
        #echo "Publishing " & msg.topic & " " & msg.payload
        discard client.publish(msg.topic, msg.payload, QOS0, false)
      of stop:
        client.disconnect(1000)
        client.destroy()      
        break

proc startMessenger(serverUrl, clientID, username, password: string) =
  open(channel)
  messengerThread.createThread(messengerLoop)
  addQuitProc(stopMessenger)
  connectMQTT(serverUrl, clientID, username, password)
  configureMessenger(arduinoIde)


# Custom proc that reads stdout, stderr separately
proc execCmdExSep*(command: string, options: set[ProcessOption] = {poUsePath}):
  tuple[stdout, stderr: TaintedString, exitCode: int] {.tags:
  [ExecIOEffect, ReadIOEffect, RootEffect], gcsafe.} =
  ## A convenience proc that runs the `command`, grabs stdout and stderr separately
  ## and returns exit code, stderr, stdout.
  ##
  ## .. code-block:: Nim
  ##
  ##  let (out, err, errC) = execCmdExSep("nim c -r mytestfile.nim")
  var p = startProcess(command, options=options + {poEvalCommand})
  var outp = outputStream(p)
  var errp = errorStream(p)
  result = (TaintedString"", TaintedString"", -1)
  var line = newStringOfCap(120).TaintedString
  while true:
    var nothing = true
    if outp.readLine(line):
      result[0].string.add(line.string)
      result[0].string.add("\n")
      nothing = false
    if errp.readLine(line):
      result[1].string.add(line.string)
      result[1].string.add("\n")
      nothing = false
    if nothing:
      result[2] = peekExitCode(p)
      if result[2] != -1: break
  close(p)

# A single object variant works fine since it's not complex
type
  JobKind = enum jkVerify, jkUpload
  Job = ref object
    case kind: JobKind
    of jkVerify, jkUpload:
      id: string         # UUID on creation of job
      board: string      # The board type string, like "arduino:avr:uno" or "arduino:avr:nano:cpu=atmega168"
      port: string       # The port to use, like "/dev/ttyACM0"
      path: string       # Full path to tempdir where source is unpacked
      sketchPath: string # Full path to sketch file like: /.../blabla/foo/foo.ino
      sketch: string     # name of sketch file only, like: foo.ino
      src: string        # base64 source of sketch, for multiple files, what do we do?
      arduinoIde: string # Full path to Arduino IDE executable

proc createVerifyJob(spec: JsonNode): Job =
  ## Create a new job with a UUID and put it into the table
  Job(kind: jkVerify, board: arduinoBoard, port: arduinoPort, sketch: spec["sketch"].getStr,
    src: spec["src"].getStr, id: generateUUID(), arduinoIde: arduinoIde)  

proc createUploadJob(spec: JsonNode): Job =
  ## Create a new job with a UUID and put it into the table
  Job(kind: jkUpload, board: arduinoBoard, port: arduinoPort, sketch: spec["sketch"].getStr,
    src: spec["src"].getStr, id: generateUUID(), arduinoIde: arduinoIde)

proc cleanWorkingDirectory() =
  echo "Cleaning out builds directory: " & buildsDirectory
  removeDir(buildsDirectory)
  createDir(buildsDirectory)

proc unpack(job: Job) =
  ## Create a job directory and unpack sources into it.
  job.path = buildsDirectory / $job.id
  var name = extractFilename(job.sketch)
  job.sketchPath = job.path / name / job.sketch
  createDir(job.path / name)
  writeFile(job.sketchPath, decode(job.src))

proc verify(job: Job):  tuple[stdout, stderr: TaintedString, exitCode: int] =
  ## Run --verify command via Arduino IDE
  echo "Starting verify job " & job.id
  let cmd = job.arduinoIde & " --verbose --verify --board " & job.board &
    " --preserve-temp-files --pref build.path=" & job.path & " " & job.sketchPath
  echo "Command " & cmd
  result = execCmdExSep(cmd)
  echo "Job done " & job.id

proc upload(job: Job):  tuple[stdout, stderr: TaintedString, exitCode: int] =
  ## Run --upload command via Arduino IDE
  echo "Starting upload job " & job.id
  # --verbose-build / --verbose-upload / --verbose
  let cmd = job.arduinoIde & " --verbose --upload --board " & job.board & " --port " & job.port &
    " --preserve-temp-files --pref build.path=" & job.path & " " & job.sketchPath
  echo "Command " & cmd
  result = execCmdExSep(cmd)
  echo "Job done " & job.id
  return

proc run(job: Job): tuple[stdout, stderr: TaintedString, exitCode: int] =
  ## Run a job by executing all tasks needed
  unpack(job)
  case job.kind
  of jkVerify:
    return job.verify()
  of jkUpload:
    return job.upload()

proc parseErrors(stderr: TaintedString, job: Job): JsonNode =
  var (_, sketchName, _) = splitFile(job.sketch)
  var lineMatcher = peg("^ '" & sketchName & r":' {\d+} ':' {.*} $")
  result = %(@[])
  var foundVerifying = false
  for line in stderr.splitLines:
    if foundVerifying:
      if line =~ lineMatcher:
        var er = %*{"line": matches[0], "message": matches[1]}
        result.add(er)
    if line.startsWith("Verifying..."):
      foundVerifying = true

proc perform(job: Job) =
  ## Perform a job and publish JSON result
  var res: JsonNode
  try:
    var (stdout, stderr, exitCode) = job.run()
    var errors = parseErrors(stderr, job)
    res = %*{"type": "success", "stdout": stdout, "stderr": stderr, "errors": errors, "exitCode": exitCode}
  except:
    res = %*{"type": "error", "message": "Failed job: " & getCurrentExceptionMsg()}
  writeFile(job.path / arduinoResultFile, $res)
  publishMQTT("result/" & job.id, $res)

proc startVerifyJob(spec: JsonNode): JsonNode =
  var job = createVerifyJob(spec)
  spawn perform(job)
  return %*{"id": job.id}

proc startUploadJob(spec: JsonNode): JsonNode =
  var job = createUploadJob(spec)
  spawn perform(job)
  return %*{"id": job.id}

proc getJobResult*(id: string): JsonNode =
  ## Check on disk for the result JSON file
  let dir = buildsDirectory / id
  if existsDir(dir):
    var resultFile = dir / arduinoResultFile
    if existsFile(resultFile):
      var res: JsonNode
      try:
        res = parseJson(readFile(resultFile))
      except:
        return %*{"error": "Bad JSON result file " & resultFile}
      return %*{"id": id, "status": "done", "result": res}
    else:
      return %*{"id": id, "status": "working"}
  else:
    return nil

proc verifyTools() =
  arduinoIde = $args["-a"]
  ## Make sure we have the tools installed we need
  if not existsFile(arduinoIde):
    echo "Can not find arduino IDE executable: " & arduinoIde
    quit 1
  else:
    echo "Found Arduino IDE: " & arduinoIde

# Verify tools
verifyTools()

# Jester routes
routes:
  get "/":
   resp p("Arduinobot is running")

  get "/test":
    var obj = newJObject()
    for k, v in request.params:
      obj[k] = %v
    resp($obj, "application/json")

  post "/verify":
    var spec: JsonNode
    try:
      spec = parseJson(request.body)
    except:
      stderr.writeLine "Unable to parse JSON body: " & request.body      
      resp Http400, "Unable to parse JSON body"
    var job = startVerifyJob(spec)
    resp($job, "application/json")

  post "/upload":
    var spec: JsonNode
    try:
      spec = parseJson(request.body)
    except:
      stderr.writeLine "Unable to parse JSON body: " & request.body      
      resp Http400, "Unable to parse JSON body"
    let job = startUploadJob(spec)
    resp($job, "application/json")

  get "/result/@id":
    ## Get result of a given job
    let res = getJobResult(@"id")
    if res.isNil:
      resp Http404, "Job not found"
    else:
      resp($res, "application/json")

# Clean out working directory
cleanWorkingDirectory()

# Start MQTT messenger thread
startMessenger(serverUrl, clientID, username, password)

# Start Jester
runForever()