# Systems Design

## NPCs

NPC simulation is a core pillar, not background decoration.

A person can have:

- name and identity
- birth date and age
- people/species
- culture
- language
- appearance seed
- traits
- aptitudes
- learned skills
- profession
- workplace
- home
- household
- possessions
- money
- health
- needs
- ambitions
- fears
- loyalties
- opinions
- knowledge
- memories
- friendships
- rivalries
- romance
- spouse
- parents
- siblings
- children
- extended family

Do not model every field at full resolution from day one. The important requirement is that the architecture can grow toward this without turning NPCs into scripted quest dispensers.

## Family and generations

Family trees are persistent.

Birth, childhood, adulthood, partnership, parenthood, aging, and death matter to the simulation.

Inheritance can eventually affect:

- property
- businesses
- social status
- wealth
- grudges
- titles
- knowledge
- cultural identity

The immortal player can become an intergenerational figure inside a family or settlement.

## Memory

NPC memory should explain future behavior.

A memory can have:

- event
- participants
- source
- emotional weight
- confidence
- timestamp
- relevance
- persistence/decay

Examples:

- player rescued my child
- player lied about a debt
- I saw the player dead
- my grandmother told me about an identical-looking youth
- the reeve warned us not to trust outsiders

Memories should not become unbounded logs. Compress, merge, decay, and retain salient events.

## Ambition and goals

NPCs should be capable of wanting things unrelated to the player.

Examples:

- own a bakery
- marry a particular person
- leave the village
- become a guild adventurer
- protect family land
- gain political office
- become wealthy
- study magic
- avenge someone
- avoid danger
- retire

Goals interact with opportunity and capability.

## Economy and work

Jobs are real relationships between people, institutions, resources, and demand.

A settlement economy can remain abstract at long distance but should produce believable local consequences.

A smith needs inputs and customers.

A farm produces food.

An inn depends on traffic.

A mine can attract labor and trade.

Shortages and surpluses influence prices, migration, and growth.

## Settlement simulation

Settlements should not have a hidden `level`.

Track causes.

Possible state:

- population
- households
- housing capacity
- food balance
- water
- employment
- production
- imports/exports
- wealth
- safety
- disease pressure
- trade access
- infrastructure
- institutions
- political authority

A settlement grows when people have reasons and ability to stay or move there.

## Information and rumor

Information has provenance.

Someone can know a fact because they:

- witnessed it
- were told directly
- heard a rumor
- read a notice
- received an official message
- inferred it

Information spreads through:

- households
- friendships
- workplaces
- taverns
- markets
- guilds
- temples
- governments
- travelers
- merchants
- soldiers

This system should power reputation and the immortality reveal.

## Journal

The journal automatically records noteworthy information the player has actually learned.

It is not a checklist.

Potential categories:

- people
- places
- rumors
- promises
- contracts
- discoveries
- personal notes generated from known events

The wording may summarize facts while preserving uncertainty.

For example:

`People at the inn say something has been taking sheep east of town.`

is different from:

`A wolf pack is located at X:123 Z:482.`

## Social trust

NPC disclosure depends on relationship and context.

A stranger might discuss:

- public directions
- prices
- public jobs
- common rumors

A trusted friend might disclose:

- family trouble
- fear
- private plans
- secrets
- politically dangerous beliefs

The player earns access socially rather than through arbitrary dialogue-level gates.

## Progression

### Practice

Skills improve through meaningful use, with anti-grind design required later.

### Knowledge

Knowledge can come from:

- people
- books
- observation
- experimentation
- culture
- institutions
- lived experience

### Technique

A technique is something specific the character knows how to do.

Examples:

- sword guard
- counter-cut
- grafting method
- fishing knot
- smithing process
- spell form

### Lifestyle

Long-term behavior affects physical and practical capability.

### Soul

Soul progression persists through death and can include:

- imprint familiarity
- reformation efficiency
- magical sensitivity
- persistent affinities

## Magic

Named spells are conventional cultural interfaces over a deeper compositional system.

A spell might include:

- source/element
- shape
- delivery
- target rule
- behavior
- duration
- magnitude
- modifiers

Established spells are teachable, socially recognized, and safer.

Experimental compositions can be more flexible and dangerous.

Advanced magic may manipulate the glyph field as an actual manifestation of the world's underlying rules.

## Soul Imprints

Acquisition pathways:

- kill
- be killed by
- bond
- study
- fresh corpse contact

Possible quality dimensions:

- anatomical understanding
- sensory understanding
- behavioral familiarity
- magical resonance
- emotional significance

A form should alter real capabilities.

Do not turn this into a collectible skin menu.

## Combat

Combat is action-oriented.

Desired ingredients:

- directional melee
- distinct weapon behavior
- block
- parry
- dodge
- stamina
- ranged attacks
- magic
- environmental interaction
- forms

### Glyph telegraphing

The renderer can communicate imminent action through glyph structure.

Examples:

- horizontal alignment for sweeping attacks
- diagonal alignment for cuts
- directional concentration for thrusts
- radial compression for shockwaves
- unstable glyphs for magical pressure

Avoid making every attack an obvious UI warning. The goal is a visual language players learn.

### Glyph disruption

Impacts can temporarily disrupt local rendering:

- displaced characters
- density bursts
- direction changes
- color inversion
- fragmentation
- reassembly

At high magical progression, deliberate manipulation becomes mechanical rather than purely cosmetic.

## Daily life

The game needs systems that make non-adventuring lives enjoyable.

Potential areas:

- farming
- fishing
- cooking
- animal care
- crafting
- trade
- home improvement
- festivals
- friendships
- romance
- parenting
- local work
- community projects

Do not build all of these early. The requirement is that the simulation model supports them coherently.

## Starting village

The player begins near a tiny rural village.

NPCs should not instantly identify the player as someone to give private problems to.

Initial interactions should reflect:

- stranger status
- curiosity
- caution
- public hospitality
- local customs
- visible age
- what the player actually says and does

Public needs can exist before arrival.

The player can:

- notice them
- ask about work
- offer help
- build trust
- simply live there

The opening should demonstrate the game's social philosophy immediately.
