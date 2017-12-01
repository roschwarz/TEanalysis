#!/usr/bin/perl
#######################################################
# Author  :  Aurelie Kapusta (https://github.com/4ureliek), with the help of Edward Chuong
# email   :  4urelie.k@gmail.com  
# Purpose :  Writen to test enrichment of TEs in a set of simple features (ChIP-seq for example) 
#######################################################
use strict;
use warnings;
use Carp;
use Getopt::Long;
use Bio::SeqIO;
use Statistics::R; #required to get the Binomial Test p-values
#use Data::Dumper;
use vars qw($BIN);
use Cwd 'abs_path';
BEGIN { 	
	$BIN = abs_path($0);
	$BIN =~ s/(.*)\/.*$/$1/;
	unshift(@INC, "$BIN/Lib");
}
use TEshuffle;

#-----------------------------------------------------------------------------
#------------------------------- DESCRIPTION ---------------------------------
#-----------------------------------------------------------------------------
#flush buffer
$| = 1;

my $version = "4.1";
my $scriptname = "TE-analysis_Shuffle_bed.pl";
my $changelog = "
#	- v1.0 = Mar 2016 
#            based on TE-analysis_Shuffle_v3+.pl, v3.3, 
#            but adapted to more general input files = bed file corresponding to any features to test.
#	- v2.0 = Mar 2016 
#            attempt of making this faster by removing any length info and allowing overlaps 
#            of shuffled features (since they are independent tests, it's OK)
#            Also added the possibility of several files to -e and -i
#   - v2.1 = Oct 2016
#            remove empty column of length info from output
#            get enrichment by age categories if age file provided
#            bug fix for total counts of hit features when upper levels (by class or family, by Rname was probably OK)
#            Changes in stats, bug fix; use R for the binomial test
#	- v3.0 = Oct 25 2016
#            TEshuffle.pm for subroutines shared with the shuffle_tr script
#	- v4.0 = Nov 28 2016
#            different choices to shuffle the TEs:
#               shufflebed = completely random positions, but same chromosome
#               shuffle inside the current TE positions, same chromosome
#               shuffle each TE, keeping its distance to a TSS, same chromosome - thanks to: Cedric Feschotte, Ed Chuong
#            make subfolders for each input file (for the shuffled outputs)
#	- v4.1 = Nov 30 2016
#            Minor bug fix: when random was 0, values were not reported 
#            (still interesting to see them in the obs, even if no stats possible)
#	- v4.2 = Dec 01 2017
#            Bug fix for when long TEs were shuffled to the position of small TEs that are
#               too close to the start of the genomic sequence (led to negative starts).
#               This is now checked for -s rm and -s tss:
#                  for -s rm, the TE is shifted of as many bp as needed
#                  for -s tss the start is simply changed to 1 (to avoid having a TE placed closer to a tss)
#            Also added the option to use -r file in -s rm as well (to check ends) and chift the TE if needed.
\n";

my $usage = "
Synopsis (v$version):

    perl $scriptname -f features.bed [-o <nt>] -q features_to_shuffle [-n <nb>] -s shuffling_type
            [-a <annotations>] 
            [-r <genome.range>] [-b] [-e <genome.gaps>] [-d] [-i <include.range>] [-x] 
            [-w <bedtools_path>] [-l <if_nonTE>] [-t <filterTE>] [-c] [-g <TE.age.tab>] [-v] [-h]

    /!\\ REQUIRES: Bedtools, at least v18 (but I advise updating up to the last version; v26 has a better shuffling)
    /!\\ Previous outputs, if any, will be moved as *.previous [which means previous results are only saved once]

    Typically, for the 3 types, the mandatory arguments are:
    perl $scriptname -f features.bed -q rm.out -s rm
    perl $scriptname -f features.bed -q rm.out -s tss -a annotations.gtf
    perl $scriptname -f features.bed -q rm.out -s bed -r genome.range -e genome.gaps
	
	Note that -r is advised for -s rm (but won't affect -s tss)

   CITATION:
    - Cite Kapusta et al. (2013) PLoS Genetics (DOI: 10.1371/journal.pgen.1003470)
      (http://journals.plos.org/plosgenetics/article?id=10.1371/journal.pgen.1003470)
      but should also include the GitHub link to this script (and version)
      Also cite Lynch et al. (2015) Cell Reports (DOI: 10.1016/j.celrep.2014.12.052) if possible
    - for BEDtools, please cite 
      Quinlan AR and Hall IM (2010) Bioinformatics (DOI: 10.1093/bioinformatics/btq033)

   DESCRIPTION:
    Features provided in -s will be overlapped with -f file (which must be simple intervals in bed format), 
       without (no_boot) or with (boot) shuffling (on same chromosome)
       One feature may overlap with several repeats and all are considered.
       However, if there are several fragments of the same repeat in a feature, it will be counted
       only one time. Could be an issue for larger features, but otherwise can't normalize by total
       number of features.
       There are 3 options for shuffling, but all will shuffle on the same chromosome:
          - with bedtool shuffle (=> random position)
            [will require files for -r and -e that can be generated by this script, see below]
          - shuffle among the current TE positions (still random, but less)
          - shuffle the TEs keeping their distance to the closest TSS of an annotation file provided
            [will require ensembl gtf, or gencode gtf or gff3 annotations]

       Note that because TEs are often fragmented + there are inversions, the counts of TEs are likely inflated;
       this also means that when TEs are shuffled, there are more fragments than TEs. Some should be moved non independently, 
       or the input file should be corrected when possible to limit that issue 
       [not implemented in this script for now, but you may edit the RM file to merge TE fragments]

    Two-tailed permutation test and a binomial test are done on the counts of overlaps. 
       The results are in a .stats.txt file. Note that high bootstraps takes a lot of time. 
       Note that for low counts, expected and/or observed, stats likely don't mean much.


   MANDATORY ARGUMENTS:	
    -f,--feat     => (STRING) ChIPseq peaks, chromatin marks, etc, in bed format
                              /!\\ Script assumes no overlap between features
    -q,--query    => (STRING) Features to shuffle = TE file
                              For now, can only be the repeat masker .out or the .bed file generated by the TE-analysis_pipeline script
                              See -l and -t for filters, and -g for age data       
    -s,--shuffle  => (STRING) Shuffling type. Should be one of the following:
                               -s bed  => use bedtools shuffle, random position on the same chromosome
                               -s rm   => shuffle inside the current TE positions; still random, but less
                               -s tss  => shuffle the TEs on the same chromosome keeping their distance
                                          to the closest TSS of an annotation file provided
                                          (TSS are shuffled and then assigned to a TE; 
                                          same TSS will be assigned multiple TEs if fewer TSS than TEs)
                                          thanks to: Cedric Feschotte and Edward Chuong for the idea

   MANDATORY ARGUMENTS IF USING -s tss:
    -a,--annot    => (STRING) gtf or gff; annotations to load all unique TSS: will be used to set the distance
                              between each TE and the closest TSS that will be kept while randomization
                              Note that it requires transcript lines

   MANDATORY ARGUMENTS IF USING -s bed:
    -r,--range    => (STRING) To know the maximum value in a given chromosome/scaffold. 
                              File should be: Name \\t length
                              Can be files from UCSC, files *.chrom.sizes
                              If you don't have such file, use -b (--build) and provide the genome fasta file for -r                               
    -e,--excl     => (STRING) This will be used as -excl for bedtools shuffle: \"coordinates in which features from -i should not be placed.\"
                              More than one file may be provided (comma separated), they will be concatenated 
                              (in a file = first-file-name.cat.bed).
                              By default, at least one file is required = assembly gaps, and it needs to be the first file
                              if not in bed format. Indeed, you may provide the UCSC gap file, with columns as:
                                  bin, chrom, chromStart, chromEnd, ix, n, size, type, bridge
                              it will be converted to a bed file. 
                              If you do nothave this file, you may provide the genome file in fasta format
                              and add the option -d (--dogaps), to generate a bed file corresponding to assembly gaps.
                              If you need to generate the <genome.gaps> file but you would also like to add more files to the -e option, 
                              just do a first run with no bootstraps (in this example the genome.range is also being generated):
                                 perl ~/bin/$scriptname -f input.bed -q genome.out -s rm -r genome.fa -b -e genome.fa -d -n 0                                
                              Other files may correspond to regions of low mappability, for example for hg19:
                              http://www.broadinstitute.org/~anshul/projects/encode/rawdata/blacklists/hg19-blacklist-README.pdf
                              Notes: -> when the bed file is generated by this script, any N stretch > 50nt will be considered as a gap 
                                        (this can be changed in the load_gap subroutine)         
                                     -> 3% of the shuffled feature may overlap with these regions 
                                        (this can be changed in the shuffle subroutine).

   OPTIONAL ARGUMENTS IF USING -s bed:
    -d,--dogaps   => (BOOL)   See above; use this and provide the genome fasta file if no gap file (-g)
                              If several files in -e, then the genome needs to be the first one.
                              This step is not optimized, it will take a while (but will create the required file)                       
    -i,--incl     => (STRING) To use as -incl for bedtools shuffle: \"coordinates in which features from -i should be placed.\"
                              Bed of gff format. Could be intervals close to TSS for example.
                              More than one file (same format) may be provided (comma separated), 
                              they will be concatenated (in a file = first-file-name.cat.bed)
    -x,--x        => (BOOL)   to add the -noOverlapping option to the bedtools shuffle command line, 
                              and therefore NOT allow overlaps between the shuffled features.
                              This may create issues mostly if -i is used (space to shuffle may be too small to shuffle features)

   OPTIONAL ARGUMENTS IF USING -s rm:
    -r,--range    => (STRING) Optional, but advised; to know the maximum TE end in a given chromosome/scaffold. 
                              File should be: Name \\t length
                              Can be files from UCSC, files *.chrom.sizes
                              If you don't have such file, use -b (--build) and provide the genome fasta file for -r   
                             
   OTHER OPTIONAL ARGUMENTS (for all -s):                                  
    -b,--build    => (BOOL)   See above; use this and provide the genome fasta file if no range/lengths file (-r)
                              This step may take a while but will create the required file	
    -o,--overlap  => (INT)    Minimal length (in nt) of intersection in order to consider the TE included in the feature.
                              Default = 10 (to match the TEanalysis-pipeline.pl)
    -n,--nboot    => (STRING) number of bootsraps with shuffled -s file
                              Default = 100 for faster runs; use higher -n for good pvalues 
                              (-n 10000 is best for permutation test but this will take a while)
                              If set to 0, no bootstrap will be done
    -w,--where    => (STRING) if BEDtools are not in your path, provide path to BEDtools bin directory                             

   OPTIONAL ARGUMENTS FOR TE FILTERING (for all -s): 
    -l,--low      => (STRING) To set the behavior regarding non TE sequences: all, no_low, no_nonTE, none
                                 -l all = keep all non TE sequences (no filtering)
                                 -l no_low [default] = keep all besides low_complexity and simple_repeat
                                 -l no_nonTE = keep all except when class = nonTE
                                 -l none = everything is filtered out (nonTE, low_complexity, simple_repeat, snRNA, srpRNA, rRNA, tRNA/tRNA, satellite)
    -t,--te       => (STRING) <type,name>
                              run the script on only a subset of repeats. Not case sensitive.
                              The type can be: name, class or family and it will be EXACT MATCH unless -c is chosen as well
                              ex: -t name,nhAT1_ML => only fragments corresponding to the repeat named exactly nhAT1_ML will be looked at
                                  -t class,DNA => all repeats with class named exactly DNA (as in ...#DNA/hAT or ...#DNA/Tc1)
                                  -t family,hAT => all repeats with family named exactly hAT (so NOT ...#DNA/hAT-Charlie for example)
    -c,--contain  => (BOOL)   to check if the \"name\" determined with -filter is included in the value in Repeat Masker output, instead of exact match
                              ex: -t name,HERVK -c => all fragments containing HERVK in their name
                                  -t family,hAT -c => all repeats with family containing hAT (...#DNA/hAT, ...#DNA/hAT-Charlie, etc)
    -g,--group    => (STRING) provide a file with TE age: 
                                 Rname  Rclass  Rfam  Rclass/Rfam  %div(avg)  lineage  age_category
                              At least Rname and lineage are required (other columns can be \"na\"),
                              and age_category can be empty. But if age_category has values, it will 
                              be used as well. Typically:
                                  TE1  LTR  ERVL-MaLR  LTR/ERVL-MaLR  24.6  Eutheria  Ancient
                                  TE2  LTR  ERVL-MaLR  LTR/ERVL-MaLR   9.9  Primates  LineageSpe
  
   OPTIONAL ARGUMENTS (GENERAL): 
    -v,--version  => (BOOL)   print the version
    -h,--help     => (BOOL)   print this usage
\n";


#-----------------------------------------------------------------------------
#------------------------------ LOAD AND CHECK -------------------------------
#-----------------------------------------------------------------------------
my ($input,$shuffle,$stype,$tssfile,$exclude,$dogaps,$build,$dobuild,$f_regexp,$allow,$nooverlaps,$v,$help);
my $inters = 10;
my $nboot = 10;
my $incl = "na";
my $nonTE = "no_low";
my $filter = "na";
my $TEage = "na";
my $bedtools = "";
my $opt_success = GetOptions(
			 	  'feat=s'		=> \$input,
			 	  'query=s'     => \$shuffle,
			 	  'shuffle=s'   => \$stype,
			 	  'overlap=s'   => \$inters,
			 	  'nboot=s'     => \$nboot,
			 	  'annot=s'     => \$tssfile,			 	  
			 	  'range=s'     => \$build,
			 	  'build'       => \$dobuild,
			 	  'excl=s'		=> \$exclude,
			 	  'dogaps'      => \$dogaps,
			 	  'incl=s'		=> \$incl,
			 	  'x'		    => \$nooverlaps,
			 	  'low=s'		=> \$nonTE,
			 	  'te=s'		=> \$filter,
			 	  'contain'     => \$f_regexp,
			 	  'group=s'     => \$TEage,
			 	  'where=s'     => \$bedtools,
			 	  'version'     => \$v,
			 	  'help'		=> \$help,);

#Check options, if files exist, etc
die "\n --- $scriptname version $version\n\n" if $v;
die $usage if ($help);
die "\n SOME MANDATORY ARGUMENTS MISSING, CHECK USAGE:\n$usage" if (! $input || ! $shuffle || ! $stype);
die "\n -f $input is not a bed file?\n\n" unless ($input =~ /\.bed$/);
die "\n -f $input does not exist?\n\n" if (! -e $input);
die "\n -q $shuffle is not in a proper format? (not .out, .bed, .gff or .gff3)\n\n" unless (($shuffle =~ /\.out$/) || ($shuffle =~ /\.bed$/) || ($shuffle =~ /\.gff$/) || ($shuffle =~ /\.gff3$/));
die "\n -q $shuffle does not exist?\n\n" if (! -e $shuffle);
die "\n -s $stype should be one of the following: bed, rm or tss\n\n" if (($stype ne "bed") && ($stype ne "rm") && ($stype ne "tss"));
#deal with conditional mandatory stuff
die "\n -s tss was set, but -a is missing?\n\n" if (($stype eq "tss") && (! $tssfile));
die "\n -a $tssfile does not exist?\n\n" if (($tssfile) && (! -e $tssfile));
if ($stype eq "bed") {
	die "\n -s bed was set, but -r is missing?\n\n" if (! $build);
	die "\n -s bed was set, but -e is missing?\n\n" if (! $exclude);
	die "\n -r $build does not exist?\n\n" if (! -e $build);
	die "\n -e $exclude does not exist?\n\n" if (($exclude !~ /,/) && (! -e $exclude)); #if several files, can't check existence here
	die "\n -i $incl does not exist?\n\n" if (($incl ne "na") && ($incl !~ /,/) && (! -e $incl)); #if several files, can't check existence here
}
#Now the rest
die "\n -n $nboot but should be an integer\n\n" if ($nboot !~ /\d+/);
die "\n -i $inters but should be an integer\n\n" if ($inters !~ /\d+/);
die "\n -w $bedtools does not exist?\n\n" if (($bedtools ne "") && (! -e $bedtools));
die "\n -t requires 2 values separated by a coma (-t <name,filter>; use -h to see the usage)\n\n" if (($filter ne "na") && ($filter !~ /,/));
die "\n -g $TEage does not exist?\n\n" if (($TEage ne "na") && (! -e $TEage));
($dogaps)?($dogaps = "y"):($dogaps = "n");
($dobuild)?($dobuild = "y"):($dobuild = "n");
($f_regexp)?($f_regexp = "y"):($f_regexp="n");
$bedtools = $bedtools."/" if (($bedtools ne "") && (substr($bedtools,-1,1) ne "/")); #put the / at the end of path if not there
($nooverlaps)?($nooverlaps = "-noOverlapping"):($nooverlaps = "");

#-----------------------------------------------------------------------------
#----------------------------------- MAIN ------------------------------------
#-----------------------------------------------------------------------------
#Prep steps
print STDERR "\n --- $scriptname v$version started, with:\n";
print STDERR "     input file = $input\n";
print STDERR "     features to shuffle = $shuffle\n";
print STDERR "     shuffling type = $stype\n";

#Outputs
print STDERR " --- prepping output directories and files\n";
my $dir = $input.".shuffle-".$stype.".".$nboot;
print STDERR "     output directory = $dir\n";
my ($stats,$out,$outb,$temp) = TEshuffle::prep_out("bed",$dir,$nboot,$filter,$input,$stype,$nonTE);

#Chosomosome sizes / Genome range
my ($okseq,$build_file);
if ($build || $dobuild) {
	print STDERR " --- loading build (genome range)\n";
	($okseq,$build_file) = TEshuffle::load_build($build,$dobuild);
}

#prep steps if shuffling type is bed
my $excl;
if ($stype eq "bed") {
	#Files to exclude for shuffling
	print STDERR " --- getting ranges to exclude in the shuffling of features from $exclude\n";
	my @exclude = ();
	if ($exclude =~ /,/) {
		($dogaps eq "y")?(print STDERR "     several files provided, -d chosen, genome file (fasta) should be the first one\n"):
						 (print STDERR "     several files provided, assembly gaps should be the first one\n");
		@exclude = split(",",$exclude) if ($exclude =~ /,/);
	} else {
		$exclude[0] = $exclude;
	}
	$exclude[0] = TEshuffle::load_gap($exclude[0],$dogaps);
	print STDERR "     concatenating files for -e\n" if ($exclude =~ /,/);
	($exclude =~ /,/)?($excl = TEshuffle::concat_beds(\@exclude)):($excl = $exclude[0]);

	#If relevant, files to include for shuffling
	if (($incl ne "na") && ($incl =~ /,/)) {
		print STDERR " --- concatenating $incl files to one file\n";
		my @include = split(",",$incl);
		$incl = TEshuffle::concat_beds(\@include);
	}
}

#Load TEage if any
print STDERR " --- Loading TE ages from $TEage\n" unless ($TEage eq "na");
my $age = ();
$age = TEshuffle::load_TEage($TEage,$v) unless ($TEage eq "na");

#Now features to shuffle (need to be after in case there was $okseq loaded)
print STDERR " --- checking file in -s, print in .bed if not a .bed or gff file\n";
print STDERR "     filtering TEs based on filter ($filter) and non TE behavior ($nonTE)\n" unless ($filter eq "na");
print STDERR "     + getting genomic counts for each repeat\n";
print STDERR "     + load all TE positions in a hash (since $stype is set to rm)\n" if ($stype eq "rm") ;
my ($toshuff_file,$parsedRM,$rm,$rm_c) = TEshuffle::RMtobed($shuffle,$okseq,$filter,$f_regexp,$nonTE,$age,"y",$stype); #Note: $rm and $rm_c are empty unless $stype eq rm

#prep steps if shuffling type is tss
my ($tssbed,$closest,$alltss);
if ($stype eq "tss")  {
	#sort TEs
	my $bedsort = $bedtools."bedtools sort";
	my $sorted = $toshuff_file;
	$sorted =~ s/\.bed$/\.sorted\.bed/;
	print STDERR " --- sorting features of $toshuff_file\n" unless (-e $sorted);	
	print STDERR "     $bedsort -i $toshuff_file > $sorted\n" unless (-e $sorted);	
	`$bedsort -i $toshuff_file > $sorted` unless (-e $sorted);
	$toshuff_file = $sorted;
	print STDERR " --- loading the tss from $tssfile\n";
	#print the tss in a bed file => use bedtools closest
	($tssbed,$alltss) = TEshuffle::load_and_print_tss($tssfile);	
	print STDERR " --- sorting features in the tss file\n" unless (-e "$tssbed.bed");
	print STDERR "     $bedsort -i $tssbed > $tssbed.bed\n" unless (-e "$tssbed.bed");
	`$bedsort -i $tssbed > $tssbed.bed` unless (-e "$tssbed.bed");
	$tssbed = $tssbed.".bed";
	#get the closest tss if relevant
	my $tssclosest = $toshuff_file.".closest.tss";
	my $closestBed = $bedtools."closestBed";
	print STDERR " --- getting closest tss for each feature in $toshuff_file, with the command line below\n";
	print STDERR "     $closestBed -a $toshuff_file -b $tssbed -D b -first > $tssclosest\n"; #I want only one entry per TE, therefore -t first
	`$closestBed -a $toshuff_file -b $tssbed -D b -t first > $tssclosest`;
	print STDERR " --- loading distance to TSS\n";
	$closest = TEshuffle::load_closest_tss($tssclosest);
}

#Get total number of features in input file (= counting number of lines with stuff in it)
print STDERR " --- getting number and length of input\n";
my $input_feat = get_features_info($input);
print STDERR "     number of features = $input_feat->{'nb'}\n";

#Join -i file with -s
my $intersectBed = $bedtools."intersectBed";
print STDERR " --- intersecting with command lines:\n";
print STDERR "        $intersectBed -a $toshuff_file -b $input -wo > $dir/no_boot.joined\n";
system "$intersectBed -a $toshuff_file -b $input -wo > $dir/no_boot.joined";

#Process the joined files
print STDERR " --- checking intersections of $input with features in $toshuff_file (observed)\n";
my $obs;
$obs = check_for_overlap("$dir/no_boot.joined","no_boot",$out,$inters,$input_feat,$obs,$age);

#Now bootstrap runs
print STDERR " --- running $nboot bootstraps now (to get significance of the overlaps)\n";
print STDERR "     with intersect command line similar to the one above,\n     and TEs shuffled amond positions from $input, keeping length info\n" if ($stype eq "rm") ;
print STDERR "     with intersect command line similar to the one above,\n     and TEs shuffled keeping same distance to TSS (using $tssbed)\n" if ($stype eq "tss") ;
if ($stype eq "bed")  {
	print STDERR "     with intersect command line similar to the one above, and shuffle command line:\n";
	($incl eq "na")?(print STDERR "        ".$bedtools."shuffleBed -i $toshuff_file -excl $excl -f 2 $nooverlaps -g $build -chrom -maxTries 10000\n"):
                    (print STDERR "        ".$bedtools."shuffleBed -incl $incl -i $toshuff_file -excl $excl -f 2 $nooverlaps -g $build -chrom -maxTries 10000\n");
}

my $boots = ();
if ($nboot > 0) {
	foreach (my $i = 1; $i <= $nboot; $i++) {
		print STDERR "     ..$i bootstraps done\n" if (($i == 10) || ($i == 100) || ($i == 1000) || (($i > 1000) && (substr($i/1000,-1,1) == 0)));	
		my $shuffled;
		$shuffled = TEshuffle::shuffle_tss($toshuff_file,$temp,$i,$alltss,$closest) if ($stype eq "tss");
		$shuffled = TEshuffle::shuffle_rm($toshuff_file,$temp,$i,$rm,$rm_c,$okseq) if ($stype eq "rm");	
		$shuffled = TEshuffle::shuffle_bed($toshuff_file,$temp,$i,$excl,$incl,$build_file,$bedtools,$nooverlaps) if ($stype eq "bed");
		system "      $intersectBed -a $shuffled -b $input -wo > $temp/boot.$i.joined";
		$boots = check_for_overlap("$temp/boot.$i.joined","boot.".$i,$outb,$inters,$input_feat,$boots,$age);
		`cat $outb >> $outb.CAT.boot.txt` if (-e $outb);
		`rm -Rf $temp/boot.$i.joined $shuffled`; #these files are now not needed anymore, all is stored
	}
}

#Stats now
print STDERR " --- getting and printing counts stats\n" if ($nboot > 0);
print_stats($stats,$obs,$boots,$nboot,$input_feat,$parsedRM,$age,$scriptname,$version) if ($nboot > 0);

#save disk space
print STDERR " --- saving disk space by deleting shuffled and joined files\n" if ($nboot > 0);
`rm -Rf $temp` if ($nboot > 0);

#end
print STDERR " --- $scriptname done\n";
print STDERR "     Stats printed in: $stats.txt\n" if ($nboot > 0);
print STDERR "\n";
exit;

#-----------------------------------------------------------------------------
#-------------------------------- SUBROUTINES --------------------------------
#-----------------------------------------------------------------------------
#-----------------------------------------------------------------------------
# Get input file info
# my $input_feat = get_features_info($input);
#-----------------------------------------------------------------------------
sub get_features_info {
	my $file = shift;
	my %info = ();		
	my $nb = `grep -c -E "\\w" $file`;
#	my $len = `more $file | awk '{SUM += (\$3-\$2)} END {print SUM}'`; #this assumes no overlaps, trusting user for now
	chomp($nb);
#	chomp($len);
	$info{'nb'} = $nb;
#	$info{'len'} = $len;				
	return(\%info);
}

#-----------------------------------------------------------------------------
# Check overlap with TEs and count for all TEs
# $no_boot = check_for_overlap("$temp/no_boot.joined","no_boot",$out,$inters,$input_feat,$no_boot,$age);
# $boots = check_for_overlap("$temp/boot.$i.joined","boot.".$i,$outb,$inters,$input_feat,$boots,$age);
#-----------------------------------------------------------------------------
sub check_for_overlap {
	my ($file,$fileid,$out,$inters,$input_feat,$counts,$age) = @_;
	my $check = ();
	open(my $fh, "<$file") or confess "\n   ERROR (sub check_for_overlap): could not open to read $file!\n";
	LINE: while(<$fh>){
		chomp(my $l = $_);
		#FYI:
		# chr1	4522383	4522590	1111;18.9;4.6;1.0;chr1;4522383;4522590;(190949381);-;B3;SINE/B2;(0);216;1;1923	.	-	chr1	4496315	4529218	[ID] [score] [strand]
		my @l = split(/\s+/,$l);	
		my $ilen = $l[-1]; #last value of the line is intersection length		
		next LINE unless ($ilen >= $inters);
		my @rm = split(";",$l[3]);
		my $Rnam = $rm[9];
		my ($Rcla,$Rfam) = TEshuffle::get_Rclass_Rfam($Rnam,$rm[10]);
		#Increment in the data structure, but only if relevant
		unless ($check->{$l[9]}{'tot'}) {
			($counts->{$fileid}{'tot'}{'tot'}{'tot'}{'tot'})?($counts->{$fileid}{'tot'}{'tot'}{'tot'}{'tot'}++):($counts->{$fileid}{'tot'}{'tot'}{'tot'}{'tot'}=1);
		}	
		unless ($check->{$l[9]}{$Rcla}) {
			($counts->{$fileid}{$Rcla}{'tot'}{'tot'}{'tot'})?($counts->{$fileid}{$Rcla}{'tot'}{'tot'}{'tot'}++):($counts->{$fileid}{$Rcla}{'tot'}{'tot'}{'tot'}=1);
			
		}
		unless ($check->{$l[9]}{$Rcla.$Rfam}) {
			($counts->{$fileid}{$Rcla}{$Rfam}{'tot'}{'tot'})?($counts->{$fileid}{$Rcla}{$Rfam}{'tot'}{'tot'}++):($counts->{$fileid}{$Rcla}{$Rfam}{'tot'}{'tot'}=1);
		}
		unless ($check->{$l[9]}{$Rcla.$Rfam.$Rnam}) {
			($counts->{$fileid}{$Rcla}{$Rfam}{$Rnam}{'tot'})?($counts->{$fileid}{$Rcla}{$Rfam}{$Rnam}{'tot'}++):($counts->{$fileid}{$Rcla}{$Rfam}{$Rnam}{'tot'}=1);	
		}
						
		#Need to check if a feature is counted several times in the upper classes
		$check->{$l[9]}{'tot'}=1;
		$check->{$l[9]}{$Rcla}=1;
		$check->{$l[9]}{$Rcla.$Rfam}=1;
		$check->{$l[9]}{$Rcla.$Rfam.$Rnam}=1;
		#Age categories if any
		if ($age->{$Rnam}) {
			unless ($check->{$l[9]}{'age'}) { #easier to load tot hit with these keys for the print_out sub
				($counts->{$fileid}{'age'}{'cat.1'}{'tot'}{'tot'})?($counts->{$fileid}{'age'}{'cat.1'}{'tot'}{'tot'}++):($counts->{$fileid}{'age'}{'cat.1'}{'tot'}{'tot'}=1); 
			}
			unless ($check->{$l[9]}{$age->{$Rnam}[4]}) {
				($counts->{$fileid}{'age'}{'cat.1'}{$age->{$Rnam}[4]}{'tot'})?($counts->{$fileid}{'age'}{'cat.1'}{$age->{$Rnam}[4]}{'tot'}++):($counts->{$fileid}{'age'}{'cat.1'}{$age->{$Rnam}[4]}{'tot'}=1);
			}
			if (($age->{$Rnam}[5]) && (! $check->{$l[9]}{$age->{$Rnam}[5]})) {
				($counts->{$fileid}{'age'}{'cat.2'}{$age->{$Rnam}[5]}{'tot'})?($counts->{$fileid}{'age'}{'cat.2'}{$age->{$Rnam}[5]}{'tot'}++):($counts->{$fileid}{'age'}{'cat.2'}{$age->{$Rnam}[5]}{'tot'}=1);
			}
			$check->{$l[9]}{'age'}=1;
			$check->{$l[9]}{$age->{$Rnam}[4]}=1;
			$check->{$l[9]}{$age->{$Rnam}[5]}=1;		
			$counts->{$fileid}{'age'}{'cat.2'}{'tot'}{'tot'}=$counts->{$fileid}{'age'}{'cat.1'}{'tot'}{'tot'};
		}
	}
	close ($fh);		
	#Now print stuff and exit
#	print STDERR "     print details in files with name base = $out\n";	
	print_out($counts,$fileid,$input_feat,$out);	
	return ($counts);
}

#-----------------------------------------------------------------------------
# Print out details of boot and no_boot stuff
# print_out($counts,$feat_hit,$fileid,$type,$out);
#-----------------------------------------------------------------------------
sub print_out {
	my ($counts,$fileid,$input_feat,$out) = @_;	
	foreach my $Rclass (keys %{$counts->{$fileid}}) {
		print_out_sub($fileid,$Rclass,"tot","tot",$counts,$input_feat,$out.".Rclass") if ($Rclass ne "age");
		foreach my $Rfam (keys %{$counts->{$fileid}{$Rclass}}) {
			print_out_sub($fileid,$Rclass,$Rfam,"tot",$counts,$input_feat,$out.".Rfam") if ($Rclass ne "age");			
			foreach my $Rname (keys %{$counts->{$fileid}{$Rclass}{$Rfam}}) {					
				print_out_sub($fileid,$Rclass,$Rfam,$Rname,$counts,$input_feat,$out.".Rname") if ($Rclass ne "age");
				print_out_sub($fileid,$Rclass,$Rfam,$Rname,$counts,$input_feat,$out.".age1") if (($Rclass eq "age") && ($Rfam eq "cat.1"));				
				print_out_sub($fileid,$Rclass,$Rfam,$Rname,$counts,$input_feat,$out.".age2") if (($Rclass eq "age") && ($Rfam eq "cat.2"));
			}
		}
	}
    return 1;
}

#-----------------------------------------------------------------------------
# Print out details of boot and no_boot stuff, bis
#-----------------------------------------------------------------------------
sub print_out_sub {
	my ($fileid,$key1,$key2,$key3,$counts,$input_feat,$out) = @_;
	my $tothit = $counts->{$fileid}{'tot'}{'tot'}{'tot'}{'tot'};
	my $hit = $counts->{$fileid}{$key1}{$key2}{$key3}{'tot'};	
	my $unhit = $input_feat->{'nb'} - $hit;
#	my $len = $counts->{$fileid}{$key1}{$key2}{$key3}{'len'}{'tot'};
	open (my $fh, ">>", $out) or confess "ERROR (sub print_out_sub): can't open to write $out $!\n";
				#fileid, class, fam, name, hits, total features loaded, unhit feat, total feat hit all categories, len <= removed length info
	print $fh "$fileid\t$key1\t$key2\t$key3\t$hit\t$input_feat->{'nb'}\t$unhit\t$tothit\n";
	close $fh;
    return 1;
}

#-----------------------------------------------------------------------------
# Print Stats (permutation test + binomial) + associated subroutines
# print_stats($stats,$obs,$boots,$nboot,$input_feat,$parsedRM,$age,$scriptname,$version) if ($nboot > 0);
#-----------------------------------------------------------------------------
sub print_stats {
	my ($out,$obs,$boots,$nboot,$input_feat,$parsedRM,$age,$scriptname,$version) = @_;
	
	#get the boot avg values, sds, agregate all values
	my $exp = get_stats_data($boots,$nboot,$obs,$parsedRM);
	$exp = TEshuffle::binomial_test_R($exp,"bed");
	
	#now print; permutation test + binomial test with avg lengths
	my $midval = $nboot/2;
	open (my $fh, ">", $out.".txt") or confess "ERROR (sub print_stats): can't open to write $out.txt $!\n";	
	print $fh "#Script $scriptname, v$version\n";
	print $fh "#Aggregated results + stats\n";
	print $fh "#Features in input file (counts):\n\t$input_feat->{'nb'}\n";
	print $fh "#With $nboot bootstraps for exp (expected); sd = standard deviation; nb = number; len = length; avg = average\n";
	print $fh "#Two tests are made (permutation and binomial) to assess how significant the difference between observed and random, so two pvalues are given\n";
	print $fh "#For the two tailed permutation test:\n";
	print $fh "#if rank is < $midval and pvalue is not \"ns\", there are significantly fewer observed values than expected \n";
	print $fh "#if rank is > $midval and pvalue is not \"ns\", there are significantly higher observed values than expected \n";
	print $fh "#The binomial test is done with binom.test from R, two sided\n";
	
	print $fh "\n#Level_(tot_means_all)\t#\t#\t#COUNTS\t#\t#\t#\t#\t#\t#\t#\t#\t#\t#\t#\t#\t#\n";
	print $fh "#Rclass\tRfam\tRname\tobs_hits\t%_obs_(%of_features)\tobs_tot_hits\tnb_of_trials(nb_of_TE_in_genome)\texp_avg_hits\texp_sd\t%_exp_(%of_features)\texp_tot_hits(avg)\tobs_rank_in_exp\t2-tailed_permutation-test_pvalue(obs.vs.exp)\tsignificance\tbinomal_test_proba\tbinomial_test_95%_confidence_interval\tbinomial_test_pval\tsignificance\n\n";
	foreach my $Rclass (keys %{$exp}) { #loop on all the repeat classes; if not in the obs then it will be 0 for obs values			
		foreach my $Rfam (keys %{$exp->{$Rclass}}) {			
			foreach my $Rname (keys %{$exp->{$Rclass}{$Rfam}}) {
				#observed
				my ($obsnb,$obsper) = (0,0);
				$obsnb = $obs->{'no_boot'}{$Rclass}{$Rfam}{$Rname}{'tot'} if ($obs->{'no_boot'}{$Rclass}{$Rfam}{$Rname}{'tot'});
				$obsper = $obsnb/$input_feat->{'nb'}*100 unless ($obsnb == 0);
				#expected
				my $expper = 0;
				my $expavg = $exp->{$Rclass}{$Rfam}{$Rname}{'avg'};	
				$expper = $expavg/$input_feat->{'nb'}*100 unless ($expavg == 0);
				#stats
				my $pval_nb = $exp->{$Rclass}{$Rfam}{$Rname}{'pval'};		
				$pval_nb = "na" if (($expavg == 0) && ($obsnb == 0));									
				#Now print stuff
				print $fh "$Rclass\t$Rfam\t$Rname\t";
				print $fh "$obsnb\t$obsper\t$obs->{'no_boot'}{'tot'}{'tot'}{'tot'}{'tot'}\t"; 
				print $fh "$parsedRM->{$Rclass}{$Rfam}{$Rname}\t"; 
				print $fh "$expavg\t$exp->{$Rclass}{$Rfam}{$Rname}{'sd'}\t$expper\t$exp->{'tot'}{'tot'}{'tot'}{'avg'}\t";			
				my $sign = TEshuffle::get_sign($pval_nb);				
				print $fh "$exp->{$Rclass}{$Rfam}{$Rname}{'rank'}\t$pval_nb\t$sign\t";								
				#Binomial
				$sign = TEshuffle::get_sign($exp->{$Rclass}{$Rfam}{$Rname}{'binom_pval'});
				print $fh "$exp->{$Rclass}{$Rfam}{$Rname}{'binom_prob'}\t$exp->{$Rclass}{$Rfam}{$Rname}{'binom_conf'}\t$exp->{$Rclass}{$Rfam}{$Rname}{'binom_pval'}\t$sign\n";	
			}
		}
	}
close $fh;
    return 1;
}

#-----------------------------------------------------------------------------
# Get the stats values 
# my $exp = get_stats_data($boots,$nboot,$obs,$parsedRM);
#-----------------------------------------------------------------------------
sub get_stats_data {
	my ($counts,$nboot,$obs,$parsedRM) = @_;
	my $exp = initialize_exp($obs,$parsedRM); #0 values for all the ones seen in obs => so that even if not seen in exp, will be there

	#agregate data
	my ($nb_c,$nb_f,$nb_r,$nb_a1,$nb_a2) = ();
	foreach my $round (keys %{$counts}) {
		foreach my $Rclass (keys %{$counts->{$round}}) {
			push(@{$nb_c->{$Rclass}{'tot'}{'tot'}},$counts->{$round}{$Rclass}{'tot'}{'tot'}{'tot'}) if ($Rclass ne "age");	
			foreach my $Rfam (keys %{$counts->{$round}{$Rclass}}) {
				push(@{$nb_f->{$Rclass}{$Rfam}{'tot'}},$counts->{$round}{$Rclass}{$Rfam}{'tot'}{'tot'}) if ($Rclass ne "age");		
				foreach my $Rname (keys %{$counts->{$round}{$Rclass}{$Rfam}}) {
					push(@{$nb_r->{$Rclass}{$Rfam}{$Rname}},$counts->{$round}{$Rclass}{$Rfam}{$Rname}{'tot'}) if ($Rclass ne "age");	
					push(@{$nb_a1->{$Rclass}{$Rfam}{$Rname}},$counts->{$round}{$Rclass}{$Rfam}{$Rname}{'tot'}) if (($Rclass eq "age") && ($Rfam eq "cat.1"));
					push(@{$nb_a2->{$Rclass}{$Rfam}{$Rname}},$counts->{$round}{$Rclass}{$Rfam}{$Rname}{'tot'}) if (($Rclass eq "age") && ($Rfam eq "cat.2"));
				}
			}
		}		
	}
	
	#get avg, sd and p values now => load in new hash, that does not have the fileID
	foreach my $round (keys %{$counts}) {
		foreach my $Rclass (keys %{$counts->{$round}}) {
			$exp = get_stats_data_details($Rclass,"tot","tot",$nb_c->{$Rclass}{'tot'}{'tot'},$exp,$obs,$nboot,$parsedRM) if ($Rclass ne "age");	
			foreach my $Rfam (keys %{$counts->{$round}{$Rclass}}) {
				$exp = get_stats_data_details($Rclass,$Rfam,"tot",$nb_f->{$Rclass}{$Rfam}{'tot'},$exp,$obs,$nboot,$parsedRM) if ($Rclass ne "age");	
				foreach my $Rname (keys %{$counts->{$round}{$Rclass}{$Rfam}}) {
					$exp = get_stats_data_details($Rclass,$Rfam,$Rname,$nb_r->{$Rclass}{$Rfam}{$Rname},$exp,$obs,$nboot,$parsedRM) if ($Rclass ne "age");
					$exp = get_stats_data_details($Rclass,$Rfam,$Rname,$nb_a1->{$Rclass}{$Rfam}{$Rname},$exp,$obs,$nboot,$parsedRM) if (($Rclass eq "age") && ($Rfam eq "cat.1"));
					$exp = get_stats_data_details($Rclass,$Rfam,$Rname,$nb_a2->{$Rclass}{$Rfam}{$Rname},$exp,$obs,$nboot,$parsedRM) if (($Rclass eq "age") && ($Rfam eq "cat.2"));
				}
			}
		}		
	}
		
	$counts = (); #empty this
	return($exp);
}

#-----------------------------------------------------------------------------
# Initialize the exp hash with the obs data, so that there will be 0s
# my $exp = initialize_exp($obs,$parsedR);
#-----------------------------------------------------------------------------
sub initialize_exp {
	my $obs = shift;
	my $exp = ();
	#obs:
	#$counts->{$fileid}{'age'}{'cat.1'}{'tot'}{'tot'}
	foreach my $f (keys %{$obs}) {
		foreach my $k1 (keys %{$obs->{$f}}) {
			foreach my $k2 (keys %{$obs->{$f}{$k1}}) {
				foreach my $k3 (keys %{$obs->{$f}{$k1}{$k2}}) {
					$exp->{$k1}{$k2}{$k3}{'avg'}=0;
					$exp->{$k1}{$k2}{$k3}{'sd'}=0;
					$exp->{$k1}{$k2}{$k3}{'p'}=0; 
					$exp->{$k1}{$k2}{$k3}{'rank'}="na";
					$exp->{$k1}{$k2}{$k3}{'pval'}="na";
				}
			}
		}
	}
	return $exp;
}

#-----------------------------------------------------------------------------
# sub get_data
# called by get_stats_data, to get average, sd, rank and p value for all the lists
#-----------------------------------------------------------------------------	
sub get_stats_data_details {
	my ($key1,$key2,$key3,$agg_data,$exp,$obs,$nboot,$parsedRM) = @_;	
	#get average and sd of the expected
	($exp->{$key1}{$key2}{$key3}{'avg'},$exp->{$key1}{$key2}{$key3}{'sd'}) = TEshuffle::get_avg_and_sd($agg_data);
	
	my $observed = $obs->{'no_boot'}{$key1}{$key2}{$key3}{'tot'};
#	print STDERR "FYI: no observed value for {$key1}{$key2}{$key3}{'tot'}\n" unless ($observed);
	$observed = 0 unless ($observed);	
	
	#Get the rank of the observed value in the list of expected + pvalue for the permutation test
	my $rank = 1; #pvalue can't be 0, so I have to start there - that does mean there will be a rank nboot+1
	my @data = sort {$a <=> $b} @{$agg_data};
	EXP: foreach my $exp (@data) {
		last EXP if ($exp > $observed);
		$rank++;
	}	
	$exp->{$key1}{$key2}{$key3}{'rank'}=$rank;
	if ($rank <= $nboot/2) {
		$exp->{$key1}{$key2}{$key3}{'pval'}=$rank/$nboot*2;
	} else {
		$exp->{$key1}{$key2}{$key3}{'pval'}=($nboot+2-$rank)/$nboot*2; #+2 so it is symetrical (around nboot+1)
	}
	
	#Binomial test
	#get all the values needed for binomial test in R => do them all at once
	my $n = $parsedRM->{$key1}{$key2}{$key3} if ($parsedRM->{$key1}{$key2}{$key3});
	$n = 0 unless ($n);
	print STDERR "        WARN: no value for total number (from RM output), for {$key1}{$key2}{$key3}? => no binomial test\n" if ($n == 0);
	my $p = 0;	
	$p=$exp->{$key1}{$key2}{$key3}{'avg'}/$n unless ($n == 0); #should not happen, but could
	$exp->{$key1}{$key2}{$key3}{'p'} = $p;
	$exp->{$key1}{$key2}{$key3}{'n'} = $n;
	$exp->{$key1}{$key2}{$key3}{'x'} = $observed;
	return($exp);
}



