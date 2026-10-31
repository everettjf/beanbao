#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#import <math.h>

// Continuous time includes time spent asleep and is unaffected by wall-clock
// corrections. An observation must not regain validity after a clock change.
static inline NSTimeInterval BBObservationClockSeconds(void) {
    mach_timebase_info_data_t scale = {0};
    if (mach_timebase_info(&scale) != KERN_SUCCESS || scale.denom == 0) return NAN;
    return (NSTimeInterval)((long double)mach_continuous_time() * scale.numer /
                            scale.denom / 1000000000.0L);
}

static inline BOOL BBObservationIsFresh(NSTimeInterval observedAt,
                                        NSTimeInterval now) {
    return isfinite(observedAt) && isfinite(now) && observedAt >= 0 &&
        now >= observedAt && now - observedAt <= 10.0;
}
