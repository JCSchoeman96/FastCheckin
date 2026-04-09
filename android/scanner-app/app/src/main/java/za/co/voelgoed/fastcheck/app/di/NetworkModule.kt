package za.co.voelgoed.fastcheck.app.di

import com.squareup.moshi.Moshi
import com.squareup.moshi.kotlin.reflect.KotlinJsonAdapterFactory
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import java.time.Clock
import javax.inject.Singleton
import okhttp3.OkHttpClient
import okhttp3.logging.HttpLoggingInterceptor
import retrofit2.Retrofit
import retrofit2.converter.moshi.MoshiConverterFactory
import za.co.voelgoed.fastcheck.core.network.ApiEnvironmentConfig
import za.co.voelgoed.fastcheck.core.network.ApiEnvironmentConfigResolver
import za.co.voelgoed.fastcheck.core.network.AuthHeaderInterceptor
import za.co.voelgoed.fastcheck.core.network.HttpLoggingPolicy
import za.co.voelgoed.fastcheck.core.network.PhoenixMobileApi
import za.co.voelgoed.fastcheck.core.network.SessionProvider
import za.co.voelgoed.fastcheck.data.remote.PhoenixMobileRemoteDataSource
import za.co.voelgoed.fastcheck.BuildConfig

@Module
@InstallIn(SingletonComponent::class)
object NetworkModule {
    @Provides
    @Singleton
    fun provideApiEnvironmentConfig(): ApiEnvironmentConfig =
        ApiEnvironmentConfigResolver().resolve()

    @Provides
    @Singleton
    fun provideAuthHeaderInterceptor(sessionProvider: SessionProvider): AuthHeaderInterceptor =
        AuthHeaderInterceptor(sessionProvider)

    @Provides
    @Singleton
    fun provideOkHttpClient(authHeaderInterceptor: AuthHeaderInterceptor): OkHttpClient =
        OkHttpClient.Builder()
            .addInterceptor(authHeaderInterceptor)
            .addInterceptor(
                HttpLoggingInterceptor().apply {
                    level = HttpLoggingPolicy.levelFor(BuildConfig.ENABLE_HTTP_BASIC_LOGGING)
                }
            )
            .build()

    @Provides
    @Singleton
    fun provideMoshi(): Moshi =
        Moshi.Builder()
            .add(KotlinJsonAdapterFactory())
            .build()

    @Provides
    @Singleton
    fun provideRetrofit(
        okHttpClient: OkHttpClient,
        moshi: Moshi,
        apiEnvironmentConfig: ApiEnvironmentConfig
    ): Retrofit =
        Retrofit.Builder()
            .baseUrl(apiEnvironmentConfig.baseUrl)
            .client(okHttpClient)
            .addConverterFactory(MoshiConverterFactory.create(moshi))
            .build()

    @Provides
    @Singleton
    fun providePhoenixMobileApi(retrofit: Retrofit): PhoenixMobileApi =
        retrofit.create(PhoenixMobileApi::class.java)

    @Provides
    @Singleton
    fun provideRemoteDataSource(
        api: PhoenixMobileApi,
        clock: Clock
    ): PhoenixMobileRemoteDataSource =
        PhoenixMobileRemoteDataSource(api, clock)
}
