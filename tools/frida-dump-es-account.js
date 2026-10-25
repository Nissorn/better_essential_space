Java.perform(function () {
    var factory = Java.use("i96$a");
    factory.a.overload("com.nothing.user.center.data.service.User").implementation = function (user) {
        try {
            var tok = user.getNothingToken();
            var third = user.getThirdPartToken();
            var uuid = user.getUuid();
            console.log("[i96$a.a] uuid=" + uuid);
            console.log("[i96$a.a] nothingToken=" + (tok === null ? "null" : tok));
            console.log("[i96$a.a] thirdPartToken=" + (third === null ? "null" : ("" + third).slice(0, 24) + "...(" + ("" + third).length + ")"));
        } catch (e) { console.log("[i96$a.a] dump err: " + e); }
        return this.a(user);
    };
    var ag = Java.use("ag");
    ag.intercept.implementation = function (chain) {
        try {
            var req = chain.request();
            console.log("[ag.intercept] " + req.method() + " " + req.url());
        } catch (e) { console.log("[ag.intercept] err " + e); }
        return this.intercept(chain);
    };
    console.log("[+] ES java hooks installed (i96$a.a, ag.intercept)");
});
