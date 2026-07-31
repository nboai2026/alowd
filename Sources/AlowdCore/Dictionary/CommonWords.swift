import Foundation

/// Embedded English + French frequency list used to keep auto-learning
/// noise-free: only tokens *absent* from this list are worth learning.
/// Entries are stored lowercased with diacritics folded ("etre", not "être");
/// use `contains(_:)` which applies the same normalization to the query.
public enum CommonWords {
    /// True when the token, lowercased and diacritics-folded (apostrophes
    /// stripped), appears in the embedded frequency list.
    public static func contains(_ token: String) -> Bool {
        words.contains(normalize(token))
    }

    /// Lowercase + fold diacritics + drop apostrophes so "Été", "ete" and
    /// "don't"/"dont" all normalize to the same key.
    public static func normalize(_ token: String) -> String {
        token
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
    }

    public static let words: Set<String> = Set(rawList.split(separator: " ").map(String.init))

    // ~1,200 English + ~800 French high-frequency words, diacritics folded.
    private static let rawList = """
        the be to of and a in that have i it for not on with he as you do at this but his by from they we say her she \
        or an will my one all would there their what so up out if about who get which go me when make can like time no \
        just him know take people into year your good some could them see other than then now look only come its over \
        think also back after use two how our work first well way even new want because any these give day most us is \
        are was were been being has had did does doing am says said went gone made knows knew taken took comes came \
        seen saw looked looks getting got wants wanted uses used works worked ways days years times things thing \
        something anything nothing everything someone anyone everyone nobody somebody anybody everybody nowhere \
        somewhere anywhere everywhere here where why what whatever whenever wherever whoever whichever three four five \
        six seven eight nine ten eleven twelve twenty thirty forty fifty hundred thousand million billion first second \
        third fourth fifth last next previous early late soon later earlier before after during while since until till \
        again once twice always never often sometimes usually rarely seldom already yet still almost quite rather \
        really very too enough much many more most less least few little lot lots plenty several each every both \
        either neither none any some all whole half quarter part piece bit item list group set number amount couple \
        pair dozen against between among within without through throughout across along around behind below beneath \
        beside besides beyond down inside outside near onto toward towards under underneath upon off above front top \
        bottom side left right middle center end beginning start finish stop open close big small large tiny huge \
        great grand long short tall high low wide narrow deep shallow thick thin heavy light fast slow quick rapid \
        hard soft easy difficult simple complex old young new fresh ancient modern early hot cold warm cool dry wet \
        clean dirty clear dark bright loud quiet noisy silent strong weak rich poor cheap expensive free busy full \
        empty ready done sure certain possible impossible likely unlikely true false real fake right wrong correct \
        incorrect exact same different similar equal opposite good bad better worse best worst fine nice great awesome \
        terrible awful horrible wonderful amazing excellent perfect pretty beautiful ugly handsome cute lovely happy \
        sad angry mad glad sorry afraid scared worried nervous calm relaxed tired sleepy awake alive dead sick ill \
        healthy hungry thirsty funny serious strange weird normal usual common rare special general particular \
        specific important necessary useful useless helpful main major minor basic extra additional final total \
        complete entire single double triple own personal private public official national international local \
        foreign domestic human animal natural artificial physical mental social political economic legal illegal \
        financial commercial industrial technical scientific medical educational cultural religious military civil \
        environmental global regional urban rural eastern western northern southern central federal state city town \
        village country nation world earth land sea ocean river lake mountain hill valley forest tree plant flower \
        grass leaf root branch seed fruit vegetable food meal breakfast lunch dinner supper snack drink water milk \
        coffee tea juice beer wine bread butter cheese meat fish chicken beef pork egg rice pasta soup salad sugar \
        salt pepper oil sauce cake cookie chocolate candy ice cream pie morning afternoon evening night midnight noon \
        today yesterday tomorrow tonight week weekend month season spring summer autumn fall winter date calendar \
        clock hour minute moment period age century decade history past present future man woman child boy girl baby \
        kid adult person people family parent father mother dad mom son daughter brother sister uncle aunt cousin \
        nephew niece grandfather grandmother grandparent husband wife partner friend neighbor stranger guest visitor \
        host member leader boss manager employee worker staff team crew colleague customer client patient doctor \
        nurse dentist teacher student pupil professor scientist engineer lawyer judge police officer soldier driver \
        pilot farmer cook chef waiter artist writer author poet singer musician actor actress dancer player coach \
        athlete king queen prince princess president minister mayor citizen public head face eye ear nose mouth lip \
        tooth teeth tongue throat neck shoulder arm elbow wrist hand finger thumb nail chest heart lung stomach back \
        waist hip leg knee ankle foot feet toe skin bone blood brain mind body hair beard voice breath health disease \
        pain ache fever cold flu cough medicine pill drug hospital clinic emergency house home apartment room bedroom \
        bathroom kitchen living dining garage garden yard door window wall floor ceiling roof stairs elevator \
        furniture table chair desk bed sofa couch shelf drawer closet mirror lamp light candle curtain carpet rug \
        pillow blanket sheet towel soap shampoo brush comb razor toilet sink bath shower key lock bell fence gate \
        path road street avenue highway bridge corner block square park playground school college university library \
        museum theater cinema church temple store shop market mall supermarket bakery pharmacy bank office building \
        factory farm station airport port harbor hotel restaurant cafe bar pub club gym pool stadium court field \
        track beach island desert jungle cave car truck bus taxi train subway tram plane airplane helicopter boat \
        ship ferry bicycle bike motorcycle wheel tire engine motor brake fuel gas petrol ticket passport luggage bag \
        suitcase backpack wallet purse money cash coin dollar euro cent price cost bill receipt tax fee fine salary \
        wage income profit loss debt loan credit card check account budget bargain sale discount trade business \
        company firm industry market economy job career profession task duty project plan goal target aim purpose \
        idea thought opinion view point fact truth lie reason cause effect result consequence problem trouble issue \
        question answer solution advice suggestion decision choice option chance opportunity risk danger safety \
        security help aid support service favor gift present prize reward award success failure mistake error fault \
        blame praise thanks apology excuse promise threat warning news information message letter note email mail \
        phone telephone mobile call text address contact name title word sentence paragraph page book magazine \
        newspaper article story novel poem chapter dictionary language english french spanish german grammar \
        spelling pronunciation accent meaning definition translation example test exam quiz grade score mark level \
        class course lesson subject topic theme homework exercise practice study research knowledge skill talent \
        ability experience education training degree diploma certificate music song tune rhythm melody concert band \
        orchestra instrument piano guitar violin drum art painting drawing picture photo photograph image film movie \
        video show program series episode channel radio television screen camera game sport football soccer \
        basketball baseball tennis golf hockey swimming running walking jumping climbing skiing skating fishing \
        hunting hiking camping travel trip journey tour vacation holiday adventure visit weather rain snow wind \
        storm thunder lightning cloud sky sun moon star space fire smoke ash dust sand stone rock metal gold silver \
        iron steel glass plastic paper wood cloth cotton wool silk leather color red blue green yellow orange purple \
        pink brown black white gray grey shape circle square triangle line dot size length width height weight speed \
        temperature degree measure meter mile inch pound ton ask tell speak talk listen hear read write draw paint \
        sing dance play win lose beat fight argue agree disagree accept refuse allow forbid let permit prevent \
        protect attack defend save rescue kill die live exist stay remain leave arrive return enter exit move stand \
        sit lie sleep wake rest relax wait hurry rush walk run jump climb fall drop rise raise lift carry hold catch \
        throw push pull drag draw send receive bring fetch deliver buy sell pay spend cost owe lend borrow keep \
        store collect gather find lose search seek discover explore invent create build destroy break fix repair \
        mend cut chop slice tear fold bend stretch squeeze press touch feel smell taste bite chew swallow eat drink \
        cook bake fry boil mix stir pour fill cover wrap pack unpack wash dry iron sew knit tie untie hang wear \
        dress undress change try fit suit match choose pick select prefer decide compare measure count calculate add \
        subtract multiply divide increase decrease grow shrink expand reduce improve worsen develop advance progress \
        succeed fail achieve manage handle deal cope solve avoid escape hide show reveal display appear disappear \
        vanish seem look sound remember forget remind recall learn teach train explain describe define mention state \
        declare announce report inform notify warn advise suggest recommend propose offer invite welcome greet \
        introduce meet visit accompany follow lead guide direct control rule govern organize arrange prepare plan \
        design intend expect hope wish want desire need require demand request beg pray thank apologize forgive \
        blame accuse admit deny confess claim prove doubt believe trust suspect guess suppose assume imagine dream \
        wonder consider regard respect admire love hate like dislike enjoy mind care matter concern interest bore \
        amuse entertain please satisfy disappoint surprise shock amaze impress annoy bother disturb interrupt upset \
        frighten scare worry comfort encourage discourage persuade convince force oblige cause make let help assist \
        serve attend join belong include exclude contain consist involve concern relate connect link attach separate \
        divide share split combine unite mix begin start continue proceed pause stop end finish complete conclude \
        okay ok yes no maybe perhaps possibly probably certainly definitely absolutely exactly actually basically \
        generally especially particularly mainly mostly partly completely totally entirely fully hardly barely \
        nearly approximately roughly instead anyway besides however although though despite unless whether \
        therefore thus hence moreover furthermore meanwhile otherwise nevertheless nonetheless indeed obviously \
        clearly apparently unfortunately fortunately luckily surprisingly honestly frankly seriously literally \
        currently recently lately finally eventually immediately suddenly quickly slowly carefully easily simply \
        directly exactly properly correctly wrongly badly nicely kindly politely rudely loudly quietly softly \
        gently strongly deeply highly widely closely nearly together alone apart forward backward upward downward \
        inward outward ahead behind aside away please welcome hello hi hey bye goodbye thanks congratulations \
        cheers sir madam mister miss missus dear love regards sincerely \
        le la les un une des de du au aux et ou mais donc or ni car ne pas plus moins tres bien mal peu beaucoup \
        trop assez si oui non peut peut-etre jamais toujours souvent parfois rarement deja encore enfin puis alors \
        ensuite apres avant pendant depuis jusque jusqu vers chez dans sur sous entre parmi contre sans avec pour \
        par comme quand lorsque comment pourquoi combien quel quelle quels quelles quoi dont lequel laquelle \
        lesquels lesquelles celui celle ceux celles ceci cela ca ce cet cette ces mon ma mes ton ta tes son sa ses \
        notre nos votre vos leur leurs mien tien sien moi toi soi lui elle nous vous eux elles je tu il on ils y en \
        se me te etre avoir faire dire aller voir savoir pouvoir vouloir venir devoir prendre trouver donner falloir \
        parler mettre passer regarder aimer croire demander rester repondre entendre penser arriver connaitre \
        devenir sentir sembler tenir comprendre rendre attendre sortir vivre entrer porter chercher ecrire appeler \
        permettre occuper montrer continuer suivre commencer suis es est sommes etes sont etais etait etions etiez \
        etaient serai sera serons serez seront serais serait ete ai as avons avez ont avais avait avions aviez \
        avaient aurai aura aurons aurez auront aurais aurait eu fais fait faisons faites font faisait ferai fera \
        ferons ferez feront ferais ferait vais va allons allez vont allais allait irai ira irons irez iront vois \
        voit voyons voyez voient voyais voyait verrai verra vu sais sait savons savez savent savait saurai su peux \
        peut pouvons pouvez peuvent pouvait pourrai pourra pourrait pu veux veut voulons voulez veulent voulait \
        voudrai voudrait voulu viens vient venons venez viennent venait viendrai venu dois doit devons devez doivent \
        devait devrai devra devrait du prends prend prenons prenez prennent prenait prendrai pris mets met mettons \
        mettez mettent mettait mis dis dit disons dites disent disait dirai vas donne donnes donnent donnait donnera \
        faut faudra faudrait fallait parle parles parlons parlez parlent parlait passe passes passons passez passent \
        passait pense penses pensons pensez pensent pensait crois croit croyons croyez croient croyait trouve \
        trouves trouvons trouvez trouvent trouvait reste restes restons restez restent restait attends attend \
        attendons attendez attendent attendait comprends comprend comprenons comprenez comprennent comprenait \
        compris homme femme enfant garcon fille bebe monsieur madame mademoiselle gens personne personnes ami amie \
        amis copain copine famille parents pere mere papa maman fils frere soeur oncle tante cousin cousine grand \
        grands mari epouse voisin voisine monde vie mort temps jour jours journee nuit matin midi soir soiree \
        semaine mois annee annees an ans heure heures minute minutes seconde moment instant fois epoque saison \
        printemps ete automne hiver hier aujourdhui aujourd demain maintenant tard tot bientot longtemps histoire \
        chose choses truc machin objet affaire affaires mot mots nom prenom phrase question reponse idee raison \
        probleme solution exemple facon maniere moyen but cause effet resultat debut fin milieu cote place endroit \
        lieu partie moitie reste ensemble groupe nombre numero fois point ligne forme taille couleur rouge bleu \
        vert jaune orange violet rose marron noir blanc gris eau feu air terre mer ocean riviere fleuve lac \
        montagne colline foret arbre plante fleur herbe feuille bois pierre sable ciel soleil lune etoile nuage \
        pluie neige vent orage temps meteo chaud froid frais sec humide pays ville village campagne region quartier \
        rue route chemin avenue place pont coin maison appartement immeuble batiment piece chambre cuisine salle \
        bain salon bureau jardin cour porte fenetre mur sol plafond toit escalier meuble table chaise lit canape \
        armoire tiroir miroir lampe lumiere cle serrure ecole college lycee universite classe cours lecon devoir \
        devoirs examen note eleve etudiant professeur prof maitre maitresse livre cahier page papier stylo crayon \
        lettre journal magazine bibliotheque musee theatre cinema film musique chanson concert art peinture tableau \
        photo image jeu jeux sport football tennis natation course marche velo voiture auto camion bus taxi train \
        metro avion bateau moto roue moteur essence billet ticket voyage vacances sejour tour visite hotel \
        restaurant cafe magasin boutique marche supermarche boulangerie pharmacie banque hopital eglise gare \
        aeroport usine ferme travail boulot metier emploi patron chef employe ouvrier equipe collegue client \
        medecin infirmiere dentiste avocat juge policier soldat conducteur pilote agriculteur cuisinier serveur \
        artiste ecrivain auteur chanteur musicien acteur actrice danseur joueur roi reine prince princesse \
        president ministre maire citoyen argent monnaie piece euro prix cout facture impot salaire achat vente \
        commerce entreprise societe industrie economie tete visage oeil yeux oreille nez bouche levre dent langue \
        gorge cou epaule bras coude main doigt pouce ongle poitrine coeur ventre dos jambe genou cheville pied \
        peau os sang cerveau esprit corps cheveux voix sante maladie douleur fievre rhume medicament nourriture \
        repas petit-dejeuner dejeuner diner gouter boisson lait the jus biere vin pain beurre fromage viande \
        poisson poulet boeuf porc oeuf riz pates soupe salade sucre sel poivre huile sauce gateau biscuit chocolat \
        bonbon glace fruit legume pomme poire orange banane fraise raisin tomate carotte pomme-de-terre patate \
        animal chien chat oiseau cheval vache mouton cochon lapin souris poule canard insecte abeille mouche \
        papillon serpent grand grande grands grandes petit petite petits petites bon bonne bons bonnes mauvais \
        mauvaise beau bel belle beaux belles nouveau nouvel nouvelle nouveaux nouvelles vieux vieil vieille jeune \
        jeunes premier premiere dernier derniere prochain prochaine autre autres meme memes tout tous toute toutes \
        quelque quelques chaque plusieurs aucun aucune certain certaine certains certaines tel telle seul seule \
        vrai vraie faux fausse juste facile difficile simple complique possible impossible important importante \
        necessaire utile inutile libre occupe plein vide pret prete propre sale long longue court courte haut \
        haute bas basse large etroit profond leger lourd fort forte faible rapide lent lente doux douce dur dure \
        chaud chaude froid froide joli jolie gentil gentille mechant sympa content contente heureux heureuse \
        triste fache desole desolee fatigue fatiguee malade calme tranquille inquiet drole serieux etrange bizarre \
        normal normale special speciale general generale particulier public publique prive privee national \
        internationale francais francaise anglais anglaise etranger cher chere gratuit pauvre riche moderne ancien \
        ancienne merci bonjour bonsoir salut aurevoir revoir bienvenue pardon excusez excuse sil plait plait \
        daccord accord voila voici allo bref donc alors enfin surtout vraiment peut-etre presque environ seulement \
        ensemble ailleurs partout nulle quelque-part dedans dehors dessus dessous devant derriere pres loin ici la \
        la-bas gauche droite droit face bout travers autour malgre selon sauf grace parce parce-que puisque afin \
        cependant pourtant neanmoins toutefois ainsi aussi egalement notamment plutot presque tellement autant \
        davantage moins mieux pire beaucoup peu jamais rien personne aucunement quelquun quelquune chacun chacune \
        tout-le-monde \
        el la los las un una unos unas de del al y o pero si no que como cuando donde quien cual cuyo porque \
        para por con sin sobre entre hasta desde hacia segun durante mediante contra tras ante bajo \
        ser estar tener hacer poder decir ir ver dar saber querer llegar pasar deber poner parecer quedar creer \
        hablar llevar dejar seguir encontrar llamar venir pensar salir volver tomar conocer vivir sentir tratar \
        mirar contar empezar esperar buscar existir entrar trabajar escribir perder producir ocurrir recibir \
        recordar terminar permitir aparecer conseguir comenzar servir sacar necesitar mantener resultar leer caer \
        cambiar presentar crear abrir considerar oir acabar convertir ganar formar traer partir morir aceptar \
        soy eres es somos son era eran fue fueron sido siendo estoy esta estamos estan estaba estuvo tengo tiene \
        tenemos tienen tenia tuvo hago hace hacemos hacen hacia hizo puedo puede podemos pueden podia pudo \
        digo dice decimos dicen decia dijo voy va vamos van iba fui veo ve vemos ven veia vio doy da damos dan \
        yo tu el ella nosotros vosotros ellos ellas usted ustedes me te se nos os le les lo mi mis su sus nuestro \
        nuestra vuestro tuyo suyo mio este esta esto estos estas ese esa eso esos esas aquel aquella aquello \
        muy mucho mucha muchos muchas poco poca pocos pocas todo toda todos todas otro otra otros otras mismo misma \
        tanto tanta tan mas menos bien mal mejor mas peor siempre nunca jamas ya todavia aun ahora antes despues \
        luego entonces hoy ayer manana tarde noche dia dias semana mes ano anos hora horas minuto momento tiempo \
        vez veces siempre casi solo solamente tambien tampoco quiza quizas acaso claro cierto verdad seguro \
        aqui alli alla ahi cerca lejos dentro fuera arriba abajo delante detras encima debajo alrededor \
        cosa cosas persona personas gente hombre mujer nino nina hijo hija padre madre familia amigo amiga \
        casa trabajo vida mundo pais ciudad lugar parte forma manera modo caso punto vez tipo grupo numero \
        agua tierra fuego aire sol luna cielo mar rio calle camino puerta ventana mesa silla libro papel \
        bueno buena buenos buenas malo mala grande pequeno pequena nuevo nueva viejo vieja joven alto alta bajo \
        largo corto ancho estrecho fuerte debil facil dificil posible imposible importante necesario util \
        primero primera segundo tercero ultimo proximo siguiente anterior mejor peor unico solo propio \
        gracias hola adios buenos senor senora por-favor perdon disculpe vale bueno pues entonces \
        der die das den dem des ein eine einen einem einer eines und oder aber wenn dass weil denn sondern \
        ich du er sie es wir ihr mich dich sich uns euch mir dir ihm ihnen mein dein sein ihre unser euer \
        sein haben werden konnen mussen sollen wollen mogen durfen machen gehen kommen sehen geben nehmen \
        sagen finden denken wissen glauben halten stehen bleiben liegen heissen heißen bringen sprechen lesen \
        schreiben spielen lernen fragen antworten arbeiten leben wohnen essen trinken schlafen fahren laufen \
        bin bist ist sind seid war waren gewesen habe hast hat hatte hatten gehabt wird wurde wurden geworden \
        kann kannst konnte muss musst musste soll sollte will willst wollte darf mag mochte \
        nicht kein keine keinen nichts nie niemals immer oft manchmal selten schon noch nur auch sehr mehr weniger \
        gut gute guter gutes besser beste schlecht gross grosse groß große klein kleine neu neue alt alte jung \
        lang kurz hoch niedrig stark schwach leicht schwer einfach schwierig moglich wichtig richtig falsch schon \
        hier dort da wo woher wohin oben unten vorne hinten links rechts innen aussen außen nah fern uberall \
        heute gestern morgen jetzt dann damals bald spater fruher wieder zuerst zuletzt endlich gleich \
        tag tage woche monat jahr jahre stunde minute zeit mal mensch menschen mann frau kind kinder leute \
        haus hause arbeit leben welt land stadt ort platz weg strasse straße tur fenster tisch buch wasser \
        was wer wie wann warum welche welcher welches wieviel etwas alles viele viel wenig jeder jede jedes \
        andere anderen beide alle man jemand niemand selbst zusammen allein eben gerade \
        auf aus bei mit nach seit von zu vor uber unter zwischen durch fur gegen ohne um an in neben hinter \
        ja nein bitte danke hallo tschuss guten entschuldigung naturlich vielleicht wirklich eigentlich \
        eins zwei drei vier funf sechs sieben acht neun zehn hundert tausend erste zweite letzte nachste
        """
}
