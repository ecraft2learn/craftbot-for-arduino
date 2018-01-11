;(function () {
  /* global $ bot */

  // Keeping state in a global object to make debugging easier
  if (!window.bot) { window.bot = {} }

  // Constants
  var fileName = 'sketch.ino'
  var portNumber = 1884

  // MQTT
  var mqttClient = null
  var editor = null

  function main () {
    $(function () {
      // When document has loaded we attach FastClick to
      // eliminate the 300 ms delay on click events.
      window.FastClick.attach(document.body)

      // Event listener for Back button.
      $('.app-back').on('click', function () { window.history.back() })

      // Create editor
      editor = window.CodeMirror.fromTextArea(document.getElementById('code'), {
        lineNumbers: true,
        matchBrackets: true,
        mode: 'text/x-csrc'
      })
      editor.setSize('100%', 500)

      // Verify and Upload buttons
      $('#verify').click(function () { verify(false) })
      $('#upload').click(function () { verify(true) })
      editor.setOption('extraKeys', {
        F5: function (cm) { verify(false) },
        F6: function (cm) { verify(true) }
      })

      // Server changed
      $('#server').change(function () { connect() })

      // Call device ready directly (this app can work without Cordova).
      onDeviceReady()
    })
  }

  function onDeviceReady () {
    // Connect to MQTT
    connect()
  }

  function connect () {
    disconnectMQTT()
    connectMQTT()
    showMessage('Connecting')
  }

  // We need a unique client id when connecting to MQTT
  function guid () {
    function s4 () {
      return Math.floor((1 + Math.random()) * 0x10000)
        .toString(16)
        .substring(1)
    }
    return s4() + s4() + '-' + s4() + '-' + s4() + '-' + s4() + '-' + s4() + s4() + s4()
  }

  function connectMQTT () {
    var clientID = guid()
    mqttClient = new window.Paho.MQTT.Client(getServer(), portNumber, clientID)
    mqttClient.onConnectionLost = onConnectionLost
    mqttClient.onMessageArrived = onMessageArrived
    var options =
      {
        userName: 'test',
        password: 'test',
        useSSL: false,
        reconnect: true,
        onSuccess: onConnectSuccess,
        onFailure: onConnectFailure
      }
    mqttClient.connect(options)
  }

  function getSource () {
    return editor.getValue()
  }

  function getServer () {
    return $('#server').val()
  }

  function cursorWait () {
    $('body').css('cursor', 'progress')
  }

  function cursorDefault () {
    $('body').css('cursor', 'default')
  }

  function verify (upload) {
    cursorWait()

    // Select command
    var command = 'verify'
    if (upload) {
      command = 'upload'
    }

    // Generate an id for the response we want to get
    var responseId = guid()

    // Subscribe in advance for that response
    subscribe('response/' + command + '/' + responseId)

    // Construct a job to run
    var job = {
      'sketch': fileName,
      'src': window.btoa(getSource())
    }

    // Submit job
    publish(command + '/' + responseId, job)
  }

  function handleResponse (topic, payload) {
    var jobId = payload.id
    subscribe('result/' + jobId)
    unsubscribe(topic)
  }

  function handleResult (topic, payload) {
    var type = payload.type
    unsubscribe(topic)
    if (type === 'success') {
      console.log('Exit code: ' + payload.exitCode)
      console.log('Stdout: ' + payload.stdout)
      console.log('Stderr: ' + payload.stderr)
      console.log('Errors: ' + JSON.stringify(payload.errors))
    } else {
      console.log('Fail:' + payload)
    }
    cursorDefault()
  }

  function onMessageArrived (message) {
    var payload = JSON.parse(message.payloadString)
    console.log('Topic: ' + message.topic + ' payload: ' + message.payloadString)
    handleMessage(message.topic, payload)
  }

  function onConnectSuccess (context) {
    showMessage('Connected')
  }

  function onConnectFailure (error) {
    console.log('Failed to connect: ' + JSON.stringify(error))
    showMessage('Connect failed')
  }

  function onConnectionLost (responseObject) {
    console.log('Connection lost: ' + responseObject.errorMessage)
    showMessage('Connection was lost')
  }

  function publish (topic, payload) {
    var message = new window.Paho.MQTT.Message(JSON.stringify(payload))
    message.destinationName = topic
    mqttClient.send(message)
  }

  function subscribe (topic) {
    mqttClient.subscribe(topic)
    console.log('Subscribed: ' + topic)
  }

  function unsubscribe (topic) {
    mqttClient.unsubscribe(topic)
    console.log('Unsubscribed: ' + topic)
  }

  function disconnectMQTT () {
    if (mqttClient) mqttClient.disconnect()
    mqttClient = null
  }

  function showMessage (message) {
    //document.querySelector('.mdl-snackbar').MaterialSnackbar.showSnackbar({message: message})
  }

  function handleMessage (topic, payload) {
    try {
      if (topic.startsWith('response/')) {
        return handleResponse(topic, payload)
      } else if (topic.startsWith('result/')) {
        return handleResult(topic, payload)
      }
      console.log('Unknown topic: ' + topic)
    } catch (error) {
      console.log('Error handling payload: ' + error)
    }
  }

  // Call main function to initialise app.
  main()
})()
