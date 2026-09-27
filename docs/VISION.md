# Vision

## One sentence

**ASCII-Life is a native Linux open-world isekai life simulation where a tiny executable generates a beautiful colored-ASCII fantasy planet, living societies, generations of NPCs, and the player's potentially centuries-long life.**

## Player fantasy

At age 15, the player appears near a tiny rural settlement in an unfamiliar fantasy world.

They understand the local spoken language, but they have no automatic social importance.

The obvious path resembles a classic isekai anime:

- discover the village
- learn how the world works
- meet adventurers
- encounter magic
- join a guild
- fight monsters
- travel
- explore dungeons
- become powerful

But that path is optional.

The player can instead:

- work
- farm
- fish
- hunt
- cook
- trade
- build a home
- make friends
- fall in love
- marry
- raise children
- help a village prosper
- become a craftsperson
- participate in local politics
- travel as a merchant
- study magic
- spend years living quietly

There is no requirement to become the hero.

## The world is not waiting

ASCII-Life should reject protagonist-centric simulation wherever possible.

If someone needs help, they seek help in ways that make sense for their life.

If the player ignores a threat, the threat continues.

If another person is capable of solving it, they may do so.

If a settlement has enough food, safety, trade, and opportunity, people can migrate there.

If it becomes poor or dangerous, people can leave.

Wars, marriages, births, careers, feuds, migrations, discoveries, disasters, and deaths happen whether or not the player sees them.

The player's story emerges from participation in this world, not from the world arranging itself into a sequence of levels.

## Time is content

Generations are a core feature.

NPCs are born, grow up, form relationships, take jobs, have children, age, and die.

The player ages too.

A person encountered as a child may later become:

- a friend
- a mayor
- a merchant
- an adventurer
- a rival
- a parent
- an old grandparent
- a name on a grave

The player can leave a village for decades and return to descendants of people they once knew.

Once the player has a stable home, the game permits deliberate longer periods of quiet life. The simulation advances rather than teleporting state.

## Immortality

Death is real but temporary.

The protagonist's unusual soul can reconstruct their body. Reanimation takes meaningful world time, after which the player reforms physically at age 15.

This creates consequences without conventional reload punishment.

If the player dies:

- the target they hunted may be gone
- their equipment may remain at the death site
- a companion may react
- a crop may go untended
- a deadline can pass
- a battle can conclude
- someone may find the corpse
- someone may witness reanimation

At first nobody knows the protagonist is immortal.

Over time, witnesses, records, rumors, portraits, family stories, governments, religions, scholars, and enemies can piece together the truth.

There is no mandatory "immortality reveal chapter."

Possible emergent outcomes include:

- a town protects the player because generations know them
- a ruler attempts capture
- a church declares them sacred
- a cult forms
- a scholar wants to study them
- people think they are a monster
- friends help hide the truth
- enemies spread propaganda
- descendants recognize stories about an ageless youth

## Soul Imprints

The protagonist can preserve a creature's biological pattern in the soul.

Possible imprint causes:

- killing the creature
- being killed by it
- prolonged observation or study
- deep bonding
- contact with sufficiently fresh remains

The acquisition path influences quality and familiarity.

Forms are mechanically meaningful.

A hawk can fly and see far.

A wolf can track by scent.

A small animal can enter spaces a human cannot.

An aquatic creature can traverse water.

Rare magical creatures may unlock dramatic late-game mobility and combat options.

The system should feel like learning another mode of embodiment, not equipping a skin.

## Progression

There is no mandatory global character level.

Progression is layered.

### Practice

Repeated meaningful use builds skill.

### Knowledge

Books, teachers, observation, experimentation, culture, and experience teach how things work.

### Technique

Specific moves, recipes, spells, craft methods, farming practices, combat forms, and professional methods can be learned.

### Lifestyle

The body adapts to a life actually lived.

A farmer, swordfighter, fisher, courier, smith, and scholar should develop differently.

### Soul

Some traits survive death and reanimation. Soul Imprints are the clearest example.

### Social progression

Guild rank, legal status, wealth, title, reputation, family ties, professional standing, religious importance, and political influence are independent systems.

Being powerful does not automatically make the player respected.

## Conversation

Conversation supports both structured intent selection and typed natural language.

Both feed the same underlying model.

Examples of intent:

- ask about a person
- ask about a place
- ask about work
- ask about a rumor
- offer help
- offer trade
- tell information
- lie
- request a favor

Typed text should be parsed into intent and entities without requiring a shipped LLM.

Responses derive from:

- what the NPC knows
- what they believe
- their personality
- relationship with the player
- current goals
- social norms
- memory
- willingness to disclose information

The player should be able to ask sensible questions before an NPC decides they are worth trusting.

## Information, not quests

There is no conventional quest object at the heart of the game.

The simulation contains:

- needs
- problems
- jobs
- promises
- rumors
- threats
- opportunities
- ambitions
- contracts

The journal automatically records noteworthy information that the player has learned.

Examples:

- "Wolves have been taking livestock east of Bellwood."
- "Mira said her brother works at the mill."
- "I promised to repair Tomas's roof before winter."
- "A caravan is expected after the new moon."

The journal is a memory aid, not an objective checklist.

## Combat

Combat is real-time action and supports first-person and third-person views.

Foundations:

- directional melee
- dodging
- blocking
- parrying
- stamina
- ranged weapons
- magic
- creature forms

The special layer is the ASCII field.

Glyph orientation and motion can communicate attack direction.

Impacts can scatter or disrupt glyphs.

Magic can warp cell selection, color, density, alignment, or local rendering rules.

At high magical understanding, manipulating the visual grammar of the world can become an in-world magical concept.

## Magic

Magic has two faces.

To an ordinary person, magic consists of named established spells, schools, traditions, and teachers.

Underneath, spells are compositions of principles such as:

- element
- shape
- delivery
- behavior
- magnitude
- persistence
- targeting
- modifiers

The player can initially learn named spells normally.

Deeper study eventually reveals their composition and enables modification or invention.

This supports both classic anime fantasy and systemic experimentation.

## Peoples and cultures

The world contains humans and recognizable fantasy peoples such as:

- beastfolk
- elves
- dwarves
- other later-defined peoples

Species is biology, not culture.

Cultures are generated from history, geography, religion, resources, neighbors, migration, and institutions.

Two beastfolk societies may have little culturally in common.

Two human kingdoms may be radically different.

Lifespans can differ by people, which matters in a generational world.

Tone may range from serious history and danger to warm domestic life. Cute beastfolk are fully intentional.

## Settlements

Settlements are simulations, not fixed level tiers.

Relevant forces include:

- population
- food
- water
- housing
- safety
- resources
- crafts
- trade access
- transport
- institutions
- wealth
- migration pressure
- political importance

Growth creates demand for physical expansion.

A village can become a town or city if conditions support it.

A city can decline.

The player can influence this without a "town upgrade" button.

A bridge, safe road, mine, farm, market, dungeon, guild hall, river port, war, disease, or trade route may reshape the settlement organically.

## World shape

The planet is finite and enormous.

It contains:

- a dominant supercontinent where much early civilization can exist
- secondary continents
- archipelagos
- large islands
- inland seas
- meaningful ocean routes

Ocean travel should create geography and history without wasting real player time.

A voyage can consume many simulated days while the player accelerates uneventful periods. Time acceleration stops for meaningful events.

Late-game forms and magic can make previously intimidating distances easier.

## Visual identity

ASCII is not a novelty overlay.

It is the game's native visual language.

The desired reaction is:

1. "That landscape looks beautiful."
2. "Wait, that is all characters?"

The renderer should use color, glyph density, orientation, silhouette, depth, light, atmosphere, motion, and material-specific character vocabularies.

The visual world should support:

- vast mountains
- dense forests
- rivers and oceans
- storms
- snow
- sunsets
- night skies
- torchlit villages
- enormous cities
- magic
- combat
- interiors
- creatures
- faces readable enough for social play

The tiny executable challenge must never become an excuse for ugliness.

## Tone

The game can contain danger, loss, war, death, and long-term consequences.

It should also make room for:

- quiet mornings
- festivals
- fishing
- awkward friendships
- domestic routines
- raising children
- cute animals
- cozy homes
- prosperous towns
- ordinary jobs
- discovering a place you want to stay

The emotional contrast is part of the appeal.
