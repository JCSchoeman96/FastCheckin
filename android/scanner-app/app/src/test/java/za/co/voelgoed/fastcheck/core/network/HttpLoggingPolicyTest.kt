package za.co.voelgoed.fastcheck.core.network

import com.google.common.truth.Truth.assertThat
import okhttp3.logging.HttpLoggingInterceptor
import org.junit.Test

class HttpLoggingPolicyTest {
    @Test
    fun debugSelectsBasicLogging() {
        assertThat(HttpLoggingPolicy.levelFor(enableBasicLogging = true))
            .isEqualTo(HttpLoggingInterceptor.Level.BASIC)
    }

    @Test
    fun releaseSelectsNoHttpLogging() {
        assertThat(HttpLoggingPolicy.levelFor(enableBasicLogging = false))
            .isEqualTo(HttpLoggingInterceptor.Level.NONE)
    }
}
