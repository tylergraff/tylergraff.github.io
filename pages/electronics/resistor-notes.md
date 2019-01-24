## Resistor Notes

### Resistors
- Design for E12 (or E6) values wherever possible. They are easy to find, and cheap:  
  `E6:  1.0       1.5       2.2       3.3       4.7       6.8`  
  `E12: 1.0  1.2  1.5  1.8  2.2  2.7  3.3  3.9  4.7  5.6  6.8  8.2`
- Metal-film construction has lower parasitic capacitance and inductance, and generally tighter tolerance (<= 5%) than carbon.
- Power rating is typically specified at 70°C *ambient* and linearly derates to 0 at 150°C
- High-power wire-wound resistors have significant inductance; use them appropriately.

### Potentiometers 
Potentiometer quality is often visually evident. Tiny trimmer pots do not hold up to daily use. Heavy panel-mounts do.  
- Form-Factors  
  **Panel-mount** - Often designed to MIL-94 (25,000 rotations), these are most robust.  
  **PCB-Mount with Shaft** - Typically designed for occasional use.  
  **PCB-Mount Trimmer** - Designed for infrequent use. Not mechanically robust. Use sparingly and carefully.  
- Construction types  
  **Cermet**  - Highest heat/power rating, low temperature coefficient. (Prefer these!)  
  **Carbon**  - High heat/power rating, high temperature coefficient.  
  **Plastic** - Low heat/power rating, high temperature coefficient.  

Resistor References:  
[Vishay-Metal-Film-Leaded-Resistors.pdf](./files/handbooks/Vishay_Metal_Film_Leaded_Resistors.pdf)  
