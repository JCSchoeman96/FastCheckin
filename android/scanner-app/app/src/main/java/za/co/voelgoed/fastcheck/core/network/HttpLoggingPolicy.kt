package za.co.voelgoed.fastcheck.core.network

import okhttp3.logging.HttpLoggingInterceptor

object HttpLoggingPolicy {
    fun levelFor(enableBasicLogging: Boolean): HttpLoggingInterceptor.Level =
        if (enableBasicLogging) {
            HttpLoggingInterceptor.Level.BASIC
        } else {
            HttpLoggingInterceptor.Level.NONE
        }
}
