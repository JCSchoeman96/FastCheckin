package za.co.voelgoed.fastcheck.feature.scanning.analysis

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class MlKitBarcodeScannerFactoryTest {
    @Test
    fun constructorDependsOnScannerFormatConfig() {
        val constructorParameterTypes =
            MlKitBarcodeScannerFactory::class.java.declaredConstructors.single().parameterTypes.toList()

        assertThat(constructorParameterTypes).contains(ScannerFormatConfig::class.java)
    }
}
