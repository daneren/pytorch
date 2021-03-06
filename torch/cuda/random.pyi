from typing import Iterable, List, Optional, Union
from .. import device as _device, Tensor


_device_t = Union[_device, int]

def get_rng_state(device: Optional[_device_t]=...) -> int: ...
def get_rng_state_all() -> List[int]: ...
def set_rng_state(new_state: Tensor, device: Optional[_device_t]=...) -> None: ...
def set_rng_state_all(new_state: Iterable[Tensor]) -> None: ...
def manual_seed(seed: int) -> None: ...
def manual_seed_all(seed: int) -> None: ...
def seed() -> None: ...
def seed_all() -> None: ...
def initial_seed() -> int: ...
