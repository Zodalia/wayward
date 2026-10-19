local _, ns = ...

-- What a levelling character buys from vendors, by the level it becomes
-- useful. Vanilla item IDs, not yet checked against Forever's vendors. Used to
-- say why a vendor is worth the trip, and to find sellers in the item data.
-- Names are English fallbacks until the client has the item cached.

ns.data.vendorGoods = {
  -- Food and drink tiers: 1, 5, 15, 25, 35, 45.
  food = {
    { id = 159, name = "Refreshing Spring Water", level = 1 },
    { id = 1179, name = "Ice Cold Milk", level = 5 },
    { id = 1205, name = "Melon Juice", level = 15 },
    { id = 1708, name = "Sweet Nectar", level = 25 },
    { id = 1645, name = "Moonberry Juice", level = 35 },
    { id = 8766, name = "Morning Glory Dew", level = 45 },
    { id = 4540, name = "Tough Hunk of Bread", level = 1 },
    { id = 4541, name = "Freshly Baked Bread", level = 5 },
    { id = 4542, name = "Moist Cornbread", level = 15 },
    { id = 4544, name = "Mulgore Spice Bread", level = 25 },
    { id = 4601, name = "Soft Banana Bread", level = 35 },
    { id = 8950, name = "Homemade Cherry Pie", level = 45 },
    { id = 117, name = "Tough Jerky", level = 1 },
    { id = 2287, name = "Haunch of Meat", level = 5 },
    { id = 3770, name = "Mutton Chop", level = 15 },
    { id = 3771, name = "Wild Hog Shank", level = 25 },
    { id = 4599, name = "Cured Ham Steak", level = 35 },
    { id = 8952, name = "Roasted Quail", level = 45 },
    { id = 4536, name = "Shiny Red Apple", level = 1 },
    { id = 4537, name = "Tel'Abim Banana", level = 5 },
    { id = 4538, name = "Snapvine Watermelon", level = 15 },
    { id = 4539, name = "Goldenbark Apple", level = 25 },
    { id = 4602, name = "Moon Harvest Pumpkin", level = 35 },
    { id = 8953, name = "Deep Fried Plantains", level = 45 },
    { id = 2070, name = "Darnassian Bleu", level = 1 },
    { id = 414, name = "Dalaran Sharp", level = 5 },
    { id = 422, name = "Dwarven Mild", level = 15 },
    { id = 1707, name = "Stormwind Brie", level = 25 },
    { id = 3927, name = "Fine Aged Cheddar", level = 35 },
    { id = 8932, name = "Alterac Swiss", level = 45 },
    { id = 4604, name = "Forest Mushroom Cap", level = 1 },
    { id = 4605, name = "Red-speckled Mushroom", level = 5 },
    { id = 4606, name = "Spongy Morel", level = 15 },
    { id = 4607, name = "Delicious Cave Mold", level = 25 },
    { id = 4608, name = "Raw Black Truffle", level = 35 },
    { id = 8948, name = "Dried King Bolete", level = 45 },
    { id = 787, name = "Slitherskin Mackerel", level = 1 },
    { id = 4592, name = "Longjaw Mud Snapper", level = 5 },
    { id = 4593, name = "Bristle Whisker Catfish", level = 15 },
    { id = 4594, name = "Rockscale Cod", level = 25 },
    { id = 21552, name = "Striped Yellowtail", level = 35 },
    { id = 8957, name = "Spinefin Halibut", level = 45 },
  },
  ammo = {
    arrow = {
      { id = 2512, name = "Rough Arrow", level = 1 },
      { id = 2515, name = "Sharp Arrow", level = 10 },
      { id = 3030, name = "Razor Arrow", level = 25 },
      { id = 11285, name = "Jagged Arrow", level = 40 },
    },
    bullet = {
      { id = 2516, name = "Light Shot", level = 1 },
      { id = 2519, name = "Heavy Shot", level = 10 },
      { id = 3033, name = "Solid Shot", level = 25 },
      { id = 11284, name = "Accurate Slugs", level = 40 },
    },
  },
  -- Class reagents, at the level of the first spell that uses them.
  reagents = {
    MAGE = {
      { id = 17056, name = "Light Feather", level = 12 },
      { id = 17031, name = "Rune of Teleportation", level = 20 },
      { id = 17032, name = "Rune of Portals", level = 40 },
      { id = 17020, name = "Arcane Powder", level = 56 },
    },
    PRIEST = {
      { id = 17056, name = "Light Feather", level = 34 },
      { id = 17028, name = "Holy Candle", level = 48 },
      { id = 17029, name = "Sacred Candle", level = 60 },
    },
    PALADIN = {
      { id = 17033, name = "Symbol of Divinity", level = 30 },
      { id = 21177, name = "Symbol of Kings", level = 52 },
    },
    SHAMAN = {
      { id = 17030, name = "Ankh", level = 30 },
    },
    DRUID = {
      { id = 17034, name = "Maple Seed", level = 20 },
      { id = 17035, name = "Stranglethorn Seed", level = 30 },
      { id = 17036, name = "Ashwood Seed", level = 40 },
      { id = 17037, name = "Hornbeam Seed", level = 50 },
      { id = 17021, name = "Wild Berries", level = 50 },
      { id = 17038, name = "Ironwood Seed", level = 60 },
      { id = 17026, name = "Wild Thornroot", level = 60 },
    },
    ROGUE = {
      { id = 3371, name = "Empty Vial", level = 20 },
      { id = 2928, name = "Dust of Decay", level = 20 },
      { id = 2930, name = "Essence of Pain", level = 20 },
      { id = 5140, name = "Flash Powder", level = 22 },
    },
    WARLOCK = {
      { id = 5565, name = "Infernal Stone", level = 50 },
      { id = 16583, name = "Demonic Figurine", level = 60 },
    },
  },
}
