// HARNESS STUB (not Android code) — annotation used by the AOSP org.json sources.
package android.annotation;
import java.lang.annotation.*;
@Retention(RetentionPolicy.SOURCE)
public @interface SystemApi {
    enum Client { PRIVILEGED_APPS, MODULE_LIBRARIES, SYSTEM_SERVER }
    Client client() default Client.PRIVILEGED_APPS;
}
