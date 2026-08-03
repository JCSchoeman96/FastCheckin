package za.co.voelgoed.fastcheck.feature.event

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.stateIn
import za.co.voelgoed.fastcheck.data.repository.EventBucketRepository

@HiltViewModel
class EventBucketsViewModel @Inject constructor(repository: EventBucketRepository) : ViewModel() {
    val buckets = repository.observeAllBuckets().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
}
