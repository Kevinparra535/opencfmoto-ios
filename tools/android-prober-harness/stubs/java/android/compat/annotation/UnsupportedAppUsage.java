// HARNESS STUB (not Android code) — annotation used by the AOSP org.json sources.
package android.compat.annotation;
import java.lang.annotation.*;
@Retention(RetentionPolicy.CLASS)
public @interface UnsupportedAppUsage {
    long trackingBug() default 0;
    int maxTargetSdk() default Integer.MAX_VALUE;
    String implicitMember() default "";
    String publicAlternatives() default "";
    String expectedSignature() default "";
}
