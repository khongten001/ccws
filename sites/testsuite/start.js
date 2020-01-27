(function(site) {
  site.addWebsocket("/test/unicode😎", "unicode😎.js");
  site.addWebsocket("/test/xmlhttprequest", "xmlhttprequest.js");
  site.addWebsocket("/test/globalevents", "globaleventlistener.js");
  site.addWebsocket("/test/eventlistener", "eventlistener.js");
  site.addWebsocket("/test/process", "process.js");
  site.addWhitelistExecutable("../../../ccws");
  var g = new GlobalEventListener('Test', 'Start Script'); g.addEventListener("ping", e => { g.globalDispatch("pong", "Start script Test")});
})
