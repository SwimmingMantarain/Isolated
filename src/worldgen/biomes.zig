pub const Biome = enum(u8) {
    Forest,
    Desert,
    Mountains,

    fn max_height(self: Biome) f64 {
        return switch (self) {
            .Forest => 60.0, // at some point there will be a sea
            .Desert => 45.0,
            .Mountains => 85.0,
        };
    }

    pub fn height(self: Biome, percent: f64) f64 {
        return self.max_height() * percent;
    }
};
