Java.perform(function () {
    try {
        var ctx = Java.use("android.app.ActivityThread").currentApplication().getApplicationContext();
        var SC = Java.use("com.nothing.security.sdk.SecurityConfig");
        var sc = SC.$new("");
        console.log("[cfg] instance created: " + sc);
        for (var i = 1; i <= 5; i++) {
            try {
                var v = sc["fetchKey" + i](ctx);
                console.log("[cfg] fetchKey" + i + " = " + v);
            } catch (e) { console.log("[cfg] fetchKey" + i + " ERR " + e); }
        }
        try {
            var cd = sc.fetchCustomData(ctx);
            console.log("[cfg] fetchCustomData = " + cd);
        } catch (e) { console.log("[cfg] fetchCustomData ERR " + e); }
    } catch (e) {
        console.log("[cfg] setup ERR " + e);
    }
});
