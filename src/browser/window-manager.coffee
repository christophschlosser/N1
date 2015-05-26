_ = require 'underscore'
fs = require 'fs-plus'
AtomWindow = require './atom-window'
BrowserWindow = require 'browser-window'
app = require 'app'

class WindowManager

  constructor: ({@devMode, @safeMode, @resourcePath, @config}) ->
    @_windows = []
    @_mainWindow = null
    @_hotWindows = {}

    @config.onDidChange 'nylas.token', =>
      @ensurePrimaryWindowOnscreen()

  ensurePrimaryWindowOnscreen: ->
    hasToken = @config.get('nylas.token')
    if hasToken
      @showMainWindow()
    else
      onboarding = @onboardingWindow() ? @newOnboardingWindow()
      onboarding.showWhenLoaded()

      @closeMainWindow()
      @unregisterAllHotWindows()
      for win in @_windows
        win.close() unless win is onboarding

  windows: ->
    @_windows

  windowWithPropsMatching: (props) ->
    _.find @_windows, (atomWindow) ->
      {windowProps} = atomWindow.loadSettings()
      return false unless windowProps
      _.every Object.keys(props), (key) -> _.isEqual(props[key],windowProps[key])

  focusedWindow: ->
    _.find @_windows, (atomWindow) -> atomWindow.isFocused()

  visibleWindows: ->
    _.filter @_windows, (atomWindow) -> atomWindow.isVisible()

  ###
  Main Window

  The main window is different from the others, because only one can exist at any
  given time and it is hidden instead of closed so that mail processing still
  happens.
  ###

  mainWindow: ->
    @_mainWindow

  sendToMainWindow: ->
    return unless @_mainWindow
    @_mainWindow.sendMessage(arguments...)

  closeMainWindow: ->
    return unless @_mainWindow
    @_mainWindow.neverClose = false
    @_mainWindow.close()
    @_mainWindow = null

  showMainWindow: ->
    if @_mainWindow
      if @_mainWindow.isMinimized()
        @_mainWindow.restore()
        @_mainWindow.focus()
      else if !@_mainWindow.isVisible()
        @_mainWindow.showWhenLoaded()

    else
      if @devMode
        try
          bootstrapScript = require.resolve(path.join(global.devResourcePath, 'src', 'window-bootstrap'))
          resourcePath = global.devResourcePath
      bootstrapScript ?= require.resolve('../window-bootstrap')
      resourcePath ?= @resourcePath

      @_mainWindow = new AtomWindow
        bootstrapScript: bootstrapScript
        resourcePath: resourcePath
        devMode: @devMode
        safeMode: @safeMode
        neverClose: true
        frame: process.platform isnt 'darwin'
        mainWindow: true


  ###
  Onboarding Window

  The onboarding window is a normal secondary window, but the WindowManager knows
  how to create it itself.
  ###

  onboardingWindow: ->
    @windowWithPropsMatching({uniqueId: 'onboarding'})

  # Returns a new onboarding window
  #
  newOnboardingWindow: ->
    @newWindow
      title: 'Welcome to Nylas'
      frame: false
      width: 340
      height: 550
      resizable: false
      windowType: 'onboarding'
      windowPackages: ['onboarding']
      windowProps:
        'uniqueId': 'onboarding'

  # Makes a new window appear of a certain `windowType`.
  #
  # In almost all cases, instead of booting up a new window from scratch,
  # we pass in new `windowProps` to a pre-loaded "hot window".
  #
  # Individual packages declare what windowTypes they support. We use this
  # to determine what packages to load in a given `windowType`. Inside a
  # package's `package.json` we expect to find an entry of the form:
  #
  #   "windowTypes": {
  #     "myCustomWindowType": true
  #     "someOtherWindowType": true
  #     "composer": true
  #   }
  #
  # Individual packages must also call `registerHotWindow` upon activation
  # to start the prepartion of `hotWindows` of various types.
  #
  # Once a hot window is registered, we'll have a hidden window with the
  # declared packages of that `windowType` pre-loaded.
  #
  # This means that when `newWindow` is called, instead of going through
  # the bootup process, it simply replaces key parameters and does a soft
  # reload via `windowPropsReceived`.
  #
  # Since the window is already loaded, there are only some options that
  # can be soft-reloaded. If you attempt to pass options that a soft
  # reload doesn't support, you'll be forced to load from a `coldStart`.
  #
  # Any options passed in here will be passed into the AtomWindow
  # constructor, which will eventually show up in the window's main
  # loadSettings, which is accessible via `atom.getLoadSettings()`
  #
  # REQUIRED options:
  #   - windowType: defaults "popout". This eventually ends up as
  #     atom.getWindowType()
  #
  # Valid options:
  #   - coldStart: true
  #   - windowProps: A good place to put any data components of the window
  #       need to initialize properly. NOTE: You can only put JSON
  #       serializable data. No functions!
  #   - title: The title of the page
  #
  # Other options that will trigger a
  #   - frame: defaults true. Whether or not the popup has a frame
  #   - forceNewWindow
  #
  # Other non required options:
  #   - All of the options of BrowserWindow
  #     https://github.com/atom/electron/blob/master/docs/api/browser-window.md#new-browserwindowoptions
  #
  # Returns a new AtomWindow
  #
  newWindow: (options={}) ->
    if options.coldStart or not @_hotWindows[options.windowType]?
      return @newColdWindow(options)
    else
      return @newHotWindow(options)

  # This sets up some windows in the background with the requested
  # packages already pre-loaded into it.
  #
  # REQUIRED options:
  #   - windowType: registers a new hot window of the given type. This is
  #   the key we use to find what packages to load and what kind of window
  #   to open
  #
  # Optional options:
  #   - replenishNum - (defaults 1) The number of hot windows to keep
  #   loaded at any given time. If your package is expected to use a large
  #   number of windows, it may be advisable to make this number more than
  #   1. Beware that each load is very resource intensive.
  #
  #   - windowPackages - A list of additional packages to load into a
  #   window in addition to those declared in various `package.json`s
  #
  registerHotWindow: ({windowType, replenishNum, windowPackages}={}) ->
    if not windowType
      throw new Error("registerHotWindow: please provide a windowType")

    @_hotWindows ?= {}
    @_hotWindows[windowType] ?= {}
    @_hotWindows[windowType].replenishNum ?= (replenishNum ? 1)
    @_hotWindows[windowType].loadedWindows ?= []
    @_hotWindows[windowType].windowPackages ?= (windowPackages ? [])

    @_replenishHotWindows()

  # Immediately close all of the hot windows and reset the replentish queue
  # to prevent more from being opened without additional calls to registerHotWindow.
  #
  # Note: This method calls `browserWindow.destroy()` which closes windows without
  # waiting for them to load or firing window lifecycle events. This is necessary
  # for the app to quit promptly on Linux. https://phab.nylas.com/T1282
  #
  unregisterAllHotWindows: ->
    for type, {loadedWindows} of @_hotWindows
      for win in loadedWindows
        win.browserWindow.destroy()
    @_replenishQueue = []
    @_hotWindows = {}

  defaultWindowOptions: ->
    devMode: @devMode
    safeMode: @safeMode
    windowType: 'popout'
    hideMenuBar: true
    resourcePath: @resourcePath
    bootstrapScript: require.resolve("../window-secondary-bootstrap")

  newColdWindow: (options={}) ->
    options = _.extend(@defaultWindowOptions(), options)
    win = new AtomWindow(options)
    win.showWhenLoaded()
    return win

  # Tries to create a new hot window. Since we're updating an existing
  # window instead of creatinga new one, there are limitations in the
  # options you can provide.
  #
  # Returns a new AtomWindow
  #
  newHotWindow: (options={}) ->
    hotWindowParams = @_hotWindows[options.windowType]
    win = null

    if not hotWindowParams?
      console.log "WindowManager: Warning! The requested windowType '#{options.windowType}'
                  has not been registered. Be sure to call `registerWindowType` first
                  in your packages setup."
      return @newColdWindow(options)

    supportedHotWindowKeys = [
      "title"
      "width"
      "height"
      "windowType"
      "windowProps"
    ]

    unsupported =  _.difference(Object.keys(options), supportedHotWindowKeys)
    if unsupported.length > 0
      console.log "WindowManager: Nylas will open a new hot window of type #{options.windowType},
                   but you are passing options that can't be applied to the preloaded window
                   (#{JSON.stringify(unsupported)}). Please change the options or pass the
                   `coldStart:true` option to use a new window instead of a hot window. If
                   it's just data for the window, please put them in the `windowProps` param."

    if hotWindowParams.loadedWindows.length is 0
      # No windows ready
      options.windowPackages = hotWindowParams.windowPackages
      win = @newColdWindow(options)
    else
      [win] = hotWindowParams.loadedWindows.splice(0,1)
      newLoadSettings = _.extend(win.loadSettings(), options)
      win.setLoadSettings(newLoadSettings)
      win.showWhenLoaded()

    @_replenishHotWindows()

    return win

  # There may be many windowTypes, each that request many windows of that
  # type (the `replenishNum`).
  #
  # Loading windows is very resource intensive, so we want to do them
  # sequentially.
  #
  # We also want to round-robin load across the breadth of window types
  # instead of loading all of the windows of a single type then moving on
  # to the next.
  #
  # We first need to cycle through the registered `hotWindows` and create
  # a breadth-first queue of window loads that we'll store in
  # `@_replenishQueue`.
  #
  # Next we need to start processing the `@_replenishQueue`
  __replenishHotWindows: =>
    @_replenishQueue = []
    queues = {}
    maxWin = 0
    for windowType, data of @_hotWindows
      numOfType = data.replenishNum - data.loadedWindows.length
      maxWin = Math.max(numOfType, maxWin)
      if numOfType > 0
        options = @defaultWindowOptions()
        options.windowType = windowType
        options.windowPackages = data.windowPackages
        queues[windowType] ?= []
        queues[windowType].push(options) for [0...numOfType]

    for [0...maxWin]
      for windowType, optionsArray of queues
        if optionsArray.length > 0
          @_replenishQueue.push(optionsArray.shift())

    @_processReplenishQueue()

  _replenishHotWindows: _.debounce(WindowManager::__replenishHotWindows, 100)

  _processReplenishQueue: ->
    return if @_processingQueue
    @_processingQueue = true
    if @_replenishQueue.length > 0
      options = @_replenishQueue.shift()
      console.log "WindowManager: Preparing a new '#{options.windowType}' window"
      newWindow = new AtomWindow(options)
      @_hotWindows[options.windowType].loadedWindows.push(newWindow)
      newWindow.once 'window:loaded', =>
        @_processingQueue = false
        @_processReplenishQueue()
    else
      @_processingQueue = false


  ###
  Methods called from AtomWindow
  ###

  # Public: Removes the {AtomWindow} from the global window list.
  removeWindow: (window) ->
    @_windows.splice @_windows.indexOf(window), 1
    @applicationMenu?.enableWindowSpecificItems(false) if @_windows.length == 0
    @windowClosedOrHidden()

  # Public: Adds the {AtomWindow} to the global window list.
  # IMPORTANT: AtomWindows add themselves - you don't need to manually add them
  addWindow: (window) ->
    @_windows.push window
    global.application.applicationMenu?.addWindow(window.browserWindow)
    window.once 'window:loaded', =>
      global.application.autoUpdateManager.emitUpdateAvailableEvent(window)

    unless window.isSpec
      focusHandler = => @lastFocusedWindow = window
      closePreventedHandler = => @windowClosedOrHidden()
      window.on 'window:close-prevented', closePreventedHandler
      window.browserWindow.on 'focus', focusHandler
      window.browserWindow.once 'closed', =>
        @lastFocusedWindow = null if window is @lastFocusedWindow
        window.removeListener('window:close-prevented', closePreventedHandler)
        window.browserWindow.removeListener('focus', focusHandler)

  windowClosedOrHidden: ->
    if process.platform in ['win32', 'linux']
      if @visibleWindows().length is 0
        # Quitting the app from within a window event handler causes
        # an assertion error. Wait a moment.
        _.defer -> app.quit()

module.exports = WindowManager