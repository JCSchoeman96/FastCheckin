package za.co.voelgoed.fastcheck.core.connectivity

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

@Singleton
class AndroidConnectivityMonitor @Inject constructor(
    @ApplicationContext context: Context
) : ConnectivityMonitor {

    private val connectivityManager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private val _isOnline = MutableStateFlow(computeOnlineSnapshot())
    override val isOnline: StateFlow<Boolean> = _isOnline

    private val callback =
        object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                _isOnline.value = computeOnlineSnapshot()
            }

            override fun onLost(network: Network) {
                _isOnline.value = computeOnlineSnapshot()
            }

            override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
                _isOnline.value = computeOnlineSnapshot()
            }
        }

    init {
        // We seed from a snapshot above; callback keeps it updated.
        connectivityManager.registerDefaultNetworkCallback(callback)
    }

    private fun computeOnlineSnapshot(): Boolean {
        val active = connectivityManager.activeNetwork ?: return false
        val capabilities = connectivityManager.getNetworkCapabilities(active) ?: return false

        val hasInternet = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        val validated = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)

        return hasInternet && validated
    }
}

