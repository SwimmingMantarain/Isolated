use std::time::{Duration, Instant};

#[derive(Clone)]
pub struct Timer {
    init_time: Option<Instant>,
}

impl Timer {
    pub fn new() -> Self {
        Self { init_time: None }
    }

    pub fn secs_since_init(&mut self) -> f64 {
        match self.init_time {
            None => {
                self.init_time = Some(Instant::now());
                0.0
            }

            Some(init) => {
                let dur: Duration = Instant::now().duration_since(init);
                dur.as_secs() as f64 + dur.subsec_nanos() as f64 * 1e-9
            }
        }
    }
}
