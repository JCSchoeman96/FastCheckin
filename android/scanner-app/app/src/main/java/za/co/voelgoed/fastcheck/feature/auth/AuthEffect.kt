package za.co.voelgoed.fastcheck.feature.auth

sealed interface AuthEffect {
    data object LoginCommitted : AuthEffect
}
