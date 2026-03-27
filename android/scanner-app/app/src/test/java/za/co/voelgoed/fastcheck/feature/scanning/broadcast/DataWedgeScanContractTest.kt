package za.co.voelgoed.fastcheck.feature.scanning.broadcast

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class DataWedgeScanContractTest {
    @Test
    fun usesLockedActionAndPayloadExtra() {
        assertThat(DataWedgeScanContract.ACTION_SCAN).isEqualTo("za.co.voelgoed.fastcheck.ACTION_SCAN")
        assertThat(DataWedgeScanContract.EXTRA_DATA_STRING)
            .isEqualTo("com.symbol.datawedge.data_string")
    }
}
