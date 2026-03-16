package za.co.voelgoed.fastcheck.app.di

import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton
import okhttp3.OkHttpClient
import okhttp3.logging.HttpLoggingInterceptor
import retrofit2.Retrofit
import retrofit2.converter.moshi.MoshiConverterFactory
import za.co.voelgoed.fastcheck.BuildConfig
import za.co.voelgoed.fastcheck.core.network.AuthHeaderInterceptor
import za.co.voelgoed.fastcheck.core.network.PhoenixMobileApi
import za.co.voelgoed.fastcheck.core.network.SessionProvider
import za.co.voelgoed.fastcheck.data.remote.PhoenixMobileRemoteDataSource

@Module
@InstallIn(SingletonComponent::class)
object NetworkModule {
    @Provides
    @Singleton
    fun provideAuthHeaderInterceptor(sessionProvider: SessionProvider): AuthHeaderInterceptor =
        AuthHeaderInterceptor(sessionProvider)

    @Provides
    @Singleton
    fun provideOkHttpClient(authHeaderInterceptor: AuthHeaderInterceptor): OkHttpClient =
        OkHttpClient.Builder()
            .addInterceptor(authHeaderInterceptor)
            .addInterceptor(HttpLoggingInterceptor().apply { level = HttpLoggingInterceptor.Level.BASIC })
            .build()

    @Provides
    @Singleton
    fun provideRetrofit(okHttpClient: OkHttpClient): Retrofit =
        Retrofit.Builder()
            .baseUrl(BuildConfig.API_BASE_URL)
            .client(okHttpClient)
            .addConverterFactory(MoshiConverterFactory.create())
            .build()

    @Provides
    @Singleton
    fun providePhoenixMobileApi(retrofit: Retrofit): PhoenixMobileApi =
        retrofit.create(PhoenixMobileApi::class.java)

    @Provides
    @Singleton
    fun provideRemoteDataSource(api: PhoenixMobileApi): PhoenixMobileRemoteDataSource =
        PhoenixMobileRemoteDataSource(api)
}
