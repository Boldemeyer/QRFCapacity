# Author: Kevin See
# Purpose: Fit QRF model to winter juvenile parr data, using CHaMP habitat data
# Created: 1/12/2020
# Last Modified: 3/20/2020
# Notes: fish density is in units of fish / m^2

#-----------------------------------------------------------------
# load needed libraries
library(QRFcapacity)
# library(maptools)
library(tidyverse)
library(janitor)
library(magrittr)
library(sf)
library(quantregForest)
library(survey)

# set default theme for ggplot
theme_set(theme_bw())

#-----------------------------------------------------------------
# determine which set of fish/habitat data to use
data("fh_win_champ_2017")
fish_hab = fh_win_champ_2017 %>%
  filter(!is.na(fish_dens)) %>%
  mutate_at(vars(Watershed, Year, Tier1),
            list(as.factor))

# and the appropriate habitat dictionrary to go with it
data("hab_dict_2017")
hab_dict = hab_dict_2017 %>%
  bind_rows(hab_dict_2017 %>%
              filter(ShortName == 'Q') %>%
              mutate(ShortName = 'Discharge')) %>%
  filter(ShortName != "DpthThlwgExit" |
           (ShortName == "DpthThlwgExit" & MetricGroupName == 'Channel Unit')) %>%
  bind_rows(tibble(ShortName = 'LWCount',
                   Name = 'Large Wood Count',
                   MetricGroupName = 'Channel Unit',
                   DescriptiveText = 'Total number of qualifying pieces of large wood',
                   UnitOfMeasure = 'count',
                   MetricCategory = 'Wood'))

# all the related habitat data
data("champ_cu")
data("champ_site_2011_17")

hab_data = champ_cu %>%
  mutate(Tier1 = recode(Tier1,
                        'Fast-NonTurbulent/Glide' = 'Run',
                        'Fast-Turbulent' = 'Riffle',
                        'Slow/Pool' = 'Pool',
                        'Small Side Channel' = 'SSC'),
         Tier1 = fct_explicit_na(Tier1)) %>%
  # add some site-scale metrics
  inner_join(champ_site_2011_17 %>%
              filter(VisitObjective == 'Primary Visit',
                     VisitStatus == 'Released to Public') %>%
               filter(!Watershed %in% c('Big-Navarro-Garcia (CA)',
                                        'CHaMP Training',
                                        'Region 17')) %>%
              select(Site, Watershed, VisitID, VisitYear,
                     Channel_Type, Elev_M, CUMDRAINAG, 
                     LON_DD, LAT_DD,
                     Discharge = Q,
                     Lgth_Wet, Area_Wet,
                     CU_Freq,
                     Sin,
                     SubD50))

# average habitat == latest channel unit habitat
data("champ_site_2011_17_avg")

hab_avg = champ_cu %>%
  mutate(Tier1 = recode(Tier1,
                        'Fast-NonTurbulent/Glide' = 'Run',
                        'Fast-Turbulent' = 'Riffle',
                        'Slow/Pool' = 'Pool',
                        'Small Side Channel' = 'SSC'),
         Tier1 = fct_explicit_na(Tier1)) %>%
  # # use VisitID as proxy for sample date
  # group_by(Site) %>%
  # filter(VisitID == max(VisitID)) %>%
  # ungroup()
  inner_join(champ_site_2011_17 %>%
              filter(VisitObjective == 'Primary Visit',
                     VisitStatus == 'Released to Public') %>%
               filter(Watershed %in% unique(hab_data$Watershed)) %>%
              select(VisitID, Site, SampleDate)) %>%
  group_by(Site) %>%
  filter(SampleDate == max(SampleDate, na.rm = T)) %>%
  ungroup() %>%
  select(-SampleDate) %>%
  # add some site-scale metrics
  left_join(champ_site_2011_17_avg %>%
              select(Site, Watershed,
                     Channel_Type, Elev_M, CUMDRAINAG, 
                     LON_DD, LAT_DD,
                     Discharge = Q,
                     Lgth_Wet, Area_Wet,
                     CU_Freq,
                     Sin,
                     SubD50))

# add a metric showing "some" fish cover
fish_hab %<>%
  mutate(FishCovSome = 100 - FishCovNone)

hab_dict %<>%
  bind_rows(hab_dict_2017 %>%
              filter(ShortName == "FishCovNone") %>%
              mutate(ShortName = "FishCovSome",
                     Name = "Fish Cover: Some Cover",
                     DescriptiveText = "Percent of wetted area with some form of fish cover"))



# all sites within Chinook domain by design

#-----------------------------------------------------------------
# select which habitat metrics to use in QRF model
# based on conversation with Mike and Richie
# sel_hab_mets = crossing(Species = c('Chinook', 
#                                     'Steelhead'),
#                         Metric = c('Tier1',
#                                    'Discharge',
#                                    'CU_Freq',
#                                    'Sin',
#                                    'SubD50',
#                                    'DpthThlwgExit',
#                                    'FishCovLW',
#                                    'SubEstGrvl'))

# updated on 3/19/20
sel_hab_mets = crossing(Species = c('Chinook', 
                                    'Steelhead'),
                        Metric = c('Tier1',
                                   'Discharge',
                                   'CU_Freq',
                                   'Sin',
                                   'SubD50',
                                   'DpthResid',
                                   'FishCovSome',
                                   'DistPrin1',
                                   'LWCount',
                                   'SubEstSandFines'))

#-----------------------------------------------------------------
# Fit QRF model
#-----------------------------------------------------------------
# impute missing data in fish / habitat dataset

# impute missing habitat metrics once, for both species
all_covars = sel_hab_mets %>%
  pull(Metric) %>%
  unique()

all_covars[!all_covars %in% names(fish_hab)]

qrf_mod_df = impute_missing_data(data = fish_hab %>%
                                   select(-(count:Nmethod), -fish_dens) %>%
                                   distinct(),
                                 covars = all_covars,
                                 impute_vars = c('Watershed', 'Elev_M', 'Sin', 'Year', 'CUMDRAINAG'),
                                 method = 'missForest') %>%
  left_join(fish_hab %>%
              select(Year:ChUnitNumber, Species, fish_dens, VisitID, Tier1)) %>%
  select(Species, Site, Watershed, Year, ChUnitNumber, SiteUnit, LON_DD, LAT_DD, fish_dens, VisitID, one_of(all_covars))

rm(all_covars)

# fit the QRF model
# set the density offset (to accommodate 0s)
dens_offset = 0.005

# fit random forest models
qrf_mods = qrf_mod_df %>%
  split(list(.$Species)) %>%
  map(.f = function(z) {
    
    covars = sel_hab_mets %>%
      filter(Species == unique(z$Species)) %>%
      pull(Metric)
    
    set.seed(3)
    qrf_mod = quantregForest(x = z %>%
                               select(one_of(covars)),
                             y = z %>%
                               mutate_at(vars(fish_dens),
                                         list(~ log(. + dens_offset))) %>%
                               select(fish_dens) %>%
                               as.matrix(),
                             keep.inbag = T,
                             ntree = 1000)
    
    return(qrf_mod)
  })

# save some results
save(fish_hab, 
     sel_hab_mets,
     qrf_mod_df,
     dens_offset,
     qrf_mods,
     hab_dict,
     file = 'output/modelFits/qrf_juv_winter.rda')

#-----------------------------------------------------------------
# create a few figures
#-----------------------------------------------------------------
load('output/modelFits/qrf_juv_winter.rda')

# relative importance of habtiat covariates
rel_imp_p = qrf_mods %>%
  map(.f = function(x) {
    as_tibble(x$importance,
              rownames = 'Metric') %>%
      mutate(relImp = IncNodePurity / max(IncNodePurity)) %>%
      left_join(hab_dict %>%
                  select(Metric = ShortName,
                         Name) %>%
                  distinct()) %>%
      mutate_at(vars(Metric, Name),
                list(~ fct_reorder(., relImp))) %>%
      arrange(Metric) %>%
      distinct() %>%
      ggplot(aes(x = Name,
                 y = relImp)) +
      geom_col(fill = 'gray40') +
      coord_flip() +
      labs(x = 'Metric',
           y = 'Relative Importance')
    
  })
# add species name to each plot
for(i in 1:length(rel_imp_p)) {
  rel_imp_p[[i]] = rel_imp_p[[i]] +
    labs(title = names(qrf_mods)[[i]])
}

ggpubr::ggarrange(plotlist = rel_imp_p,
                  nrow = 2,
                  ncol = 1)


# for Chinook
chnk_pdp = plot_partial_dependence_v2(qrf_mods[['Chinook']],
                                      data = qrf_mod_df %>%
                                        filter(Species == 'Chinook'),
                                      data_dict = hab_dict,
                                      log_offset = dens_offset,
                                      scales = 'free') +
  labs(title = 'Chinook')

# for steelhead
sthd_pdp = plot_partial_dependence_v2(qrf_mods[['Steelhead']],
                                      data = qrf_mod_df %>%
                                        filter(Species == 'Steelhead'),
                                      data_dict = hab_dict,
                                      log_offset = dens_offset,
                                      scales = 'free') +
  labs(title = 'Steelhead')


#-----------------------------------------------------------------
# predict capacity at all CHaMP sites
#-----------------------------------------------------------------
load('output/modelFits/qrf_juv_winter.rda')

# what quantile is a proxy for capacity?
pred_quant = 0.9

covars = unique(sel_hab_mets$Metric)
covars = covars[-grep('Tier1', covars)]

hab_impute = hab_data %>%
  filter(!is.na(Tier1),
         Tier1 != "(Missing)") %>%
  mutate_at(vars(Watershed, Channel_Type, Tier1),
            list(fct_drop)) %>%
  impute_missing_data(data = .,
                      covars = covars,
                      impute_vars = c(#'Watershed', 
                        'Elev_M', 
                        'Channel_Type', 
                        'CUMDRAINAG'),
                      method = 'Hmisc') %>%
  select(Site, Watershed, VisitID, LON_DD, LAT_DD, VisitYear, Lgth_Wet, ChUnitNumber, Tier1, Tier2, AreaTotal, one_of(covars))

pred_hab_cu = hab_impute %>%
  mutate(chnk_per_m2 = predict(qrf_mods[['Chinook']],
                              newdata = select(., one_of(unique(sel_hab_mets$Metric))),
                              what = pred_quant),
         chnk_per_m2 = exp(chnk_per_m2) - dens_offset) %>%
  mutate(sthd_per_m2 = predict(qrf_mods[['Steelhead']],
                              newdata = select(., one_of(unique(sel_hab_mets$Metric))),
                              what = pred_quant),
         sthd_per_m2 = exp(sthd_per_m2) - dens_offset)

# sum channel unit capacities up to site-scale, then take average capacity of site across years
pred_hab_sites = pred_hab_cu %>%
  mutate(chnk_capN = chnk_per_m2 * AreaTotal,
         sthd_capN = sthd_per_m2 * AreaTotal) %>%
  group_by(VisitID, Site, Watershed) %>%
  summarise_at(vars(ends_with('capN')),
               list(sum)) %>%
  ungroup() %>%
  group_by(Site, Watershed) %>%
  summarise_at(vars(chnk_capN, sthd_capN),
               list(mean)) %>%
  ungroup() %>%
  left_join(champ_site_2011_17_avg %>%
              select(Site, Watershed, LON_DD, LAT_DD, Lgth_Wet, Area_Wet)) %>%
  mutate(chnk_per_m = chnk_capN / Lgth_Wet,
         chnk_per_m2 = chnk_capN / Area_Wet,
         sthd_per_m = sthd_capN / Lgth_Wet,
         sthd_per_m2 = sthd_capN / Area_Wet) %>%
  mutate_at(vars(ends_with('capN')),
            list(round)) %>%
  select(Site, Watershed, LON_DD, LAT_DD, 
         Lgth_Wet, Area_Wet,
         starts_with('chnk'),
         starts_with('sthd'))

# filter out sites outside the Chinook domain
data("chnk_domain")
snap_dist = 1000

pred_hab_sites_chnk = pred_hab_sites %>%
  filter(!is.na(LON_DD)) %>%
  st_as_sf(coords = c('LON_DD', 'LAT_DD'),
           crs = 4326) %>%
  st_transform(crs = st_crs(chnk_domain)) %>%
  as_Spatial() %>%
  maptools::snapPointsToLines(chnk_domain %>%
                                mutate(id = 1:n()) %>%
                                select(id, MPG) %>%
                                as_Spatial(),
                              maxDist = snap_dist,
                              withAttrs = T,
                              idField = 'id') %>%
  as('sf') %>%
  as_tibble()

# note if sites are in Chinook domain or not
pred_hab_sites %<>% 
  mutate(chnk_domain = if_else(Site %in% pred_hab_sites_chnk$Site, T, F)) %>%
  mutate_at(vars(Watershed),
            list(fct_drop))

# put into dataframe for extrapolation, keeping only Chinook sites in Chinook domain
pred_hab_df = pred_hab_sites %>%
  select(-starts_with('chnk')) %>%
  rename(cap_per_m = sthd_per_m,
         cap_per_m2 = sthd_per_m2) %>%
  mutate(Species = 'Steelhead') %>%
  bind_rows(pred_hab_sites %>%
              select(-starts_with('sthd')) %>%
              filter(chnk_domain) %>%
              select(-chnk_domain) %>%
              rename(cap_per_m = chnk_per_m,
                     cap_per_m2 = chnk_per_m2) %>%
              mutate(Species = 'Chinook')) %>%
  select(Species, everything(),
         -ends_with('capN'))
  

#----------------------------------------
# pull in survey design related data
#----------------------------------------
# Calculate GRTS design weights.

# pull in info about what strata each CHaMP site was assigned to (using 2014 as reference year)
site_strata = pred_hab_df %>%
  select(Species, Site, Watershed) %>%
  distinct() %>%
  left_join(gaa %>%
              select(Site,
                     strata = AStrat2014)) %>%
  mutate(site_num = str_split(Site, '-', simplify = T)[,2]) %>%
  mutate(strata = if_else(Watershed == 'Asotin',
                          site_num,
                          if_else(Watershed == 'Entiat' & grepl('ENT00001', Site),
                                  paste('EntiatIMW', site_num, sep = '_'),
                                  strata))) %>%
  mutate(strata = if_else(grepl('EntiatIMW', strata),
                          str_remove(strata, '[[:digit:]]$'),
                          strata),
         strata = if_else(grepl('EntiatIMW', strata),
                          str_remove(strata, '[[:digit:]]$'),
                          strata)) %>%
  filter(!is.na(strata)) %>%
  mutate(strata = paste(Watershed, strata, sep = '_')) %>%
  select(-site_num)

# read in data from the CHaMP frame
champ_frame_df = read_csv('data/prepped/champ_frame_data.csv') %>%
  mutate(Target2014 = ifelse(is.na(AStrat2014), 'Non-Target', Target2014)) %>%
  mutate(AStrat2014 = ifelse(AStrat2014 == 'Entiat IMW', paste('EntiatIMW', GeoRchIMW, sep = '_'), AStrat2014)) %>%
  filter(Target2014 == 'Target') %>%
  rename(Watershed = CHaMPshed)

# what strata do we have?
frame_strata = champ_frame_df %>%
  mutate(strata = paste(Watershed, AStrat2014, sep='_')) %>%
  select(Watershed, 
         strata) %>%
  distinct()

# how long is each strata, by species?
chnk_strata_length = champ_frame_df %>%
  filter(!is.na(UseTypCHSP)) %>%
  mutate(strata = paste(Watershed, AStrat2014, sep='_')) %>%
  select(Watershed, matches("Strat"), FrameLeng) %>%
  group_by(Watershed, strata) %>%
  summarise(tot_length_km = sum(FrameLeng) / 1000) %>%
  ungroup() %>%
  mutate_at(vars(Watershed, strata), 
            list(as.factor)) %>%
  arrange(Watershed, strata)

sthd_strata_length = champ_frame_df %>%
  filter(!is.na(UseTypSTSU)) %>%
  mutate(strata = paste(Watershed, AStrat2014, sep='_')) %>%
  select(Watershed, matches("Strat"), FrameLeng) %>%
  group_by(Watershed, strata) %>%
  summarise(tot_length_km = sum(FrameLeng) / 1000) %>%
  bind_rows(tibble(Watershed = 'Asotin',
                   strata = paste('Asotin', c('CC', 'NF', 'SF'), sep = '_'),
                   tot_length_km = 12)) %>%
  ungroup() %>%
  mutate_at(vars(Watershed, strata), 
            list(as.factor)) %>%
  arrange(Watershed, strata)

strata_length = chnk_strata_length %>%
  mutate(Species = 'Chinook') %>%
  bind_rows(sthd_strata_length %>%
              mutate(Species = 'Steelhead')) %>%
  select(Species, everything())

# how many sites in each strata? and what is the length of each strata?
strata_tab = pred_hab_df %>%
  select(Species, Site, Watershed, matches('per_m')) %>%
  left_join(site_strata) %>%
  filter(strata != 'Entiat_Entiat IMW') %>%
  mutate_at(vars(Watershed),
            list(fct_drop)) %>%
  group_by(Species, Watershed, strata) %>%
  summarise(n_sites = n_distinct(Site)) %>%
  ungroup() %>%
  full_join(strata_length) %>%
  mutate(n_sites = if_else(is.na(n_sites),
                           as.integer(0),
                           n_sites)) %>%
  # calculate the weight of each site in each strata
  mutate(site_weight = if_else(n_sites > 0,
                               tot_length_km / n_sites,
                               as.numeric(NA)))


# test to see if we've accounted for all strata and most of each watershed
strata_test = frame_strata %>%
  full_join(strata_tab) %>%
  mutate_at(vars(Watershed),
            list(fct_drop)) %>%
  mutate(n_sites = if_else(is.na(n_sites),
                           as.integer(0),
                           n_sites)) %>%
  select(Species, everything()) %>%
  arrange(Species, Watershed, strata)

# # what frame strata don't have any sites in them?
# strata_test %>%
#   filter(n_sites == 0,
#          !is.na(tot_length_km)) %>%
#   arrange(Species, Watershed, strata) %>%
#   as.data.frame()

# # what strata that we have sites for are not in the frame strata?
# strata_test %>%
#   filter(n_sites > 0,
#          (is.na(tot_length_km) |
#             tot_length_km == 0)) %>%
#   as.data.frame()

# # how much of each watershed is not accounted for with current sites / strata?
# strata_test %>%
#   group_by(Watershed) %>%
#   summarise_at(vars(tot_length_km),
#                list(sum),
#                na.rm = T) %>%
#   left_join(strata_test %>%
#               filter(n_sites == 0) %>%
#               group_by(Watershed) %>%
#               summarise_at(vars(missing_length = tot_length_km),
#                            list(sum),
#                            na.rm = T)) %>%
#   mutate_at(vars(missing_length),
#             list(~ if_else(is.na(.), 0, .))) %>%
#   mutate(perc_missing = missing_length / tot_length_km) %>%
#   mutate_at(vars(perc_missing),
#             list(~ if_else(is.na(.), 0, .))) %>%
#   arrange(desc(perc_missing))

# Prep GAAs for extrapolation
data("gaa")

gaa_all = gaa %>%
  rename(Channel_Type = ChanlType)

# which GAAs to use
gaa_covars = c('TRange', 
               # 'GDD', 
               # 'Precip',
               'Elev_M', 
               'CHaMPsheds', 
               'NatPrin1', 
               # 'NatPrin2', 
               'DistPrin1', 
               # 'BFW_M', 
               'SrtCumDrn', 
               'StrmPwr',
               'Slp_NHD_v1', 
               'Channel_Type', 
               # 'MAVELV', 
               'WIDE_BF',
               'S2_02_11')

# what type of covariate is each GAA?
gaa_class = gaa_all %>%
  select(one_of(gaa_covars)) %>%
  as.list() %>%
  map_chr(.f = class)

# which ones are numeric?
gaa_num = names(gaa_class)[gaa_class %in% c('integer', 'numeric')]
# which ones are categorical?
gaa_catg = names(gaa_class)[gaa_class %in% c('factor', 'character')]

# compare range of covariates from model dataset and prediction dataset
range_comp = bind_rows(gaa_all %>%
                         filter(!Site %in% unique(pred_hab_sites$Site)) %>%
                         select(Site,
                                one_of(gaa_num)) %>%
                         gather(Metric, value, -Site) %>%
                         mutate(Source = 'non-CHaMP Sites'),
                       gaa_all %>%
                         filter(Site %in% unique(pred_hab_sites$Site)) %>%
                         select(Site,
                                one_of(gaa_num)) %>%
                         distinct() %>%
                         gather(Metric, value, -Site) %>%
                         mutate(Source = 'CHaMP Sites')) %>%
  mutate_at(vars(Source, Metric),
            list(as.factor))

range_max = range_comp %>%
  group_by(Metric, Source) %>%
  summarise_at(vars(value),
               tibble::lst(min, max),
               na.rm = T) %>%
  filter(Source == 'CHaMP Sites') %>%
  ungroup() %>%
  gather(type, value, -Metric, -Source)

# Center the covariates
# filter out sites with covariates outside range of covariates used to fit extrapolation model
out_range_sites = gaa_all %>%
  # filter out a few areas
  filter(!HUC6NmNRCS %in% c('Upper Sacramento', 'Southern Oregon Coastal', 'Puget Sound', 'Northern California Coastal', 'Oregon Closed Basins')) %>%
  # don't use AEM sites in model
  filter(!grepl('^AEM', Site)) %>%
  select(one_of(gaa_num), Site) %>%
  gather(Metric, value, -Site) %>%
  left_join(select(range_max, -Source) %>%
              spread(type, value)) %>%
  group_by(Metric) %>%
  filter(value > max |
           value < min) %>%
  ungroup() %>%
  pull(Site) %>%
  unique()

# center covariates
gaa_summ = inner_join(pred_hab_df %>%
                        select(Site) %>%
                        distinct(),
                      gaa_all %>%
                        select(Site, one_of(gaa_num))) %>%
  gather(GAA, value, -Site) %>%
  group_by(GAA) %>%
  summarise(metric_mean = mean(value, na.rm=T),
            metric_sd = sd(value, na.rm=T)) %>%
  ungroup()

# extrapolation model data set, with normalized covariates
mod_data = inner_join(pred_hab_df %>%
                        select(Species:Watershed,
                               matches('per_m')),
                      gaa_all %>%
                        select(Site, one_of(gaa_num))) %>%
  gather(GAA, value, one_of(gaa_num)) %>%
  left_join(gaa_summ) %>%
  mutate(norm_value = (value - metric_mean) / metric_sd) %>%
  select(-(value:metric_sd)) %>%
  spread(GAA, norm_value) %>%
  left_join(gaa_all %>%
              select(Site, one_of(gaa_catg)))

# drop NAs
mod_data %<>%
  bind_cols(mod_data %>%
              is.na() %>%
              as_tibble() %>%
              select(one_of(gaa_covars)) %>%
              transmute(n_NA = rowSums(.))) %>%
  filter(n_NA == 0) %>%
  mutate_at(vars(Watershed, CHaMPsheds, Channel_Type),
            list(fct_drop)) 

# calculate adjusted weights for all predicted QRF capacity sites
mod_data_weights = mod_data %>%
  left_join(site_strata) %>%
  left_join(strata_tab) %>%
  filter(!is.na(site_weight)) %>%
  group_by(Species, Watershed) %>%
  mutate(sum_weights = sum(site_weight)) %>%
  ungroup() %>%
  mutate(adj_weight = site_weight / sum_weights)


# where do we want to make extrapolation predictions?
gaa_pred = gaa_all %>%
  # filter out a few areas
  filter(!HUC6NmNRCS %in% c('Upper Sacramento', 'Southern Oregon Coastal', 'Puget Sound', 'Northern California Coastal', 'Oregon Closed Basins')) %>%
  # don't use AEM sites in model
  filter(!grepl('^AEM', Site)) %>%
  # don't use non-GRTS sites
  filter(SiteID_alt != 'NonGRTSSite' | is.na(SiteID_alt)) %>%
  filter(!grepl('mega', Site, ignore.case = T)) %>%
  # note which sites have GAAs outside range of CHaMP sites GAAs
  mutate(inCovarRange = ifelse(Site %in% out_range_sites, F, T)) %>%
  select(Site, one_of(gaa_covars), Lon, Lat, inCovarRange, HUC6NmNRCS, HUC8NmNRCS, HUC10NmNRC, HUC12NmNRC, chnk, steel) %>%
  gather(GAA, value, one_of(gaa_num)) %>%
  left_join(gaa_summ) %>%
  mutate(norm_value = (value - metric_mean) / metric_sd) %>%
  select(-(value:metric_sd)) %>%
  spread(GAA, norm_value)

#-------------------------------------------------------------
# Set up the survey design.

# getOption('survey.lonely.psu')
# this will prevent strata with only 1 site from contributing to the variance
# options(survey.lonely.psu = 'certainty')
# this centers strata with only 1 site to the sample grand mean; this is conservative
options(survey.lonely.psu = 'adjust')

# extrapolation model formula
full_form = as.formula(paste('log(qrf_cap) ~ -1 + (', paste(gaa_covars, collapse = ' + '), ')'))

# fit various models
model_svy_df = mod_data_weights %>%
  gather(response, qrf_cap, matches('per_m')) %>%
  select(-(n_sites:sum_weights)) %>%
  group_by(Species, response) %>%
  nest() %>%
  mutate(design = map(data,
                      .f = function(x) {
                        svydesign(id = ~ 1,
                                  data = x,
                                  strata = ~ Watershed,
                                  # strata = ~ strata,
                                  weights = ~ adj_weight)
                      })) %>%
  mutate(mod_full = map(design,
                        .f = function(x) {
                          svyglm(full_form,
                                 design = x)
                        }),
         mod_no_champ = map(design,
                            .f = function(x) {
                              svyglm(update(full_form, .~ . -CHaMPsheds),
                                     design = x)
                            })) %>%
  arrange(Species, response) %>%
  ungroup()


# predictions within CHaMP watersheds, using the model that includes CHaMPsheds as a covariate
y = gaa_pred %>%
  filter(CHaMPsheds %in% unique(model_svy_df$data[[1]]$Watershed)) %>%
  select(Site, CHaMPsheds, one_of(gaa_covars)) %>%
  na.omit() %>%
  left_join(gaa_pred) %>%
  mutate_at(vars(Channel_Type),
            list(as.factor))

per_m_preds = model_svy_df %>%
  filter(Species == 'Chinook',
         response == 'cap_per_m') %>%
  pull(mod_full) %>%
  extract2(1) %>%
  predict(.,
          newdata = y,
          se = T,
          type = 'response') %>%
  as_tibble() %>%
  rename(chnk_per_m = response,
         chnk_per_m_se = SE) %>%
  bind_cols(model_svy_df %>%
              filter(Species == 'Steelhead',
                     response == 'cap_per_m') %>%
              pull(mod_full) %>%
              extract2(1) %>%
              predict(.,
                      newdata = y,
                      se = T,
                      type = 'response') %>%
              as_tibble() %>%
              rename(sthd_per_m = response,
                     sthd_per_m_se = SE))


per_m2_preds = model_svy_df %>%
  filter(Species == 'Chinook',
         response == 'cap_per_m2') %>%
  pull(mod_full) %>%
  extract2(1) %>%
  predict(.,
          newdata = y,
          se = T,
          type = 'response') %>%
  as_tibble() %>%
  rename(chnk_per_m2 = response,
         chnk_per_m2_se = SE) %>%
  bind_cols(model_svy_df %>%
              filter(Species == 'Steelhead',
                     response == 'cap_per_m2') %>%
              pull(mod_full) %>%
              extract2(1) %>%
              predict(.,
                      newdata = y,
                      se = T,
                      type = 'response') %>%
              as_tibble() %>%
              rename(sthd_per_m2 = response,
                     sthd_per_m2_se = SE))

y %<>%
  bind_cols(per_m_preds) %>%
  bind_cols(per_m2_preds) %>%
  mutate_at(vars(matches('per_m')),
            list(exp))

rm(per_m_preds,
   per_m2_preds)

# predictions at all points, using the model without CHaMPsheds as a covariate
z = gaa_pred %>%
  select(Site, one_of(gaa_covars), -CHaMPsheds) %>%
  na.omit() %>%
  left_join(gaa_pred) %>%
  mutate_at(vars(Channel_Type),
            list(as.factor))

per_m_preds = model_svy_df %>%
  filter(Species == 'Chinook',
         response == 'cap_per_m') %>%
  pull(mod_no_champ) %>%
  extract2(1) %>%
  predict(.,
          newdata = z,
          se = T,
          type = 'response') %>%
  as_tibble() %>%
  rename(chnk_per_m = response,
         chnk_per_m_se = SE) %>%
  bind_cols(model_svy_df %>%
              filter(Species == 'Steelhead',
                     response == 'cap_per_m') %>%
              pull(mod_no_champ) %>%
              extract2(1) %>%
              predict(.,
                      newdata = z,
                      se = T,
                      type = 'response') %>%
              as_tibble() %>%
              rename(sthd_per_m = response,
                     sthd_per_m_se = SE))


per_m2_preds = model_svy_df %>%
  filter(Species == 'Chinook',
         response == 'cap_per_m2') %>%
  pull(mod_no_champ) %>%
  extract2(1) %>%
  predict(.,
          newdata = z,
          se = T,
          type = 'response') %>%
  as_tibble() %>%
  rename(chnk_per_m2 = response,
         chnk_per_m2_se = SE) %>%
  bind_cols(model_svy_df %>%
              filter(Species == 'Steelhead',
                     response == 'cap_per_m2') %>%
              pull(mod_no_champ) %>%
              extract2(1) %>%
              predict(.,
                      newdata = z,
                      se = T,
                      type = 'response') %>%
              as_tibble() %>%
              rename(sthd_per_m2 = response,
                     sthd_per_m2_se = SE))

z %<>%
  bind_cols(per_m_preds) %>%
  bind_cols(per_m2_preds) %>%
  mutate_at(vars(matches('per_m')),
            list(exp))


rm(per_m_preds, per_m2_preds)

# put all predictions together
all_preds = y %>%
  mutate(model = 'CHaMP') %>%
  bind_rows(z %>%
              mutate(model = 'non-CHaMP'))

# quick comparison of capacity predicitons with both models
comp_pred_p = all_preds %>%
  filter(Site %in% Site[duplicated(Site)]) %>%
  # select(Site, CHaMPsheds, Channel_Type, model, chnk_per_m, chnk_per_m2) %>%
  select(Site, CHaMPsheds, Channel_Type, model, chnk_per_m, chnk_per_m2, sthd_per_m, sthd_per_m2) %>%
  arrange(CHaMPsheds, Site, model) %>%
  gather(dens_type, cap, matches('_per_m')) %>%
  spread(model, cap) %>%
  ggplot(aes(x = CHaMP,
             y = `non-CHaMP`)) +
  geom_point() +
  geom_abline(linetype = 2,
              color = 'red') +
  facet_wrap(~ CHaMPsheds + dens_type,
             scales = 'free')

comp_pred_p

# for sites in CHaMP watersheds, use predicions from CHaMP extrapolation model
all_preds %<>%
  filter((Site %in% Site[duplicated(Site)] & model == 'CHaMP') |
           !Site %in% Site[duplicated(Site)])

# for CHaMP sites, use direct QRF esimates, not extrapolation ones
all_preds %<>%
  left_join(mod_data %>%
              select(Site, 
                     Species,
                     cap_per_m) %>%
              spread(Species, cap_per_m) %>%
              rename(qrf_chnk_per_m = Chinook,
                     qrf_sthd_per_m = Steelhead) %>%
              full_join(mod_data %>%
                          select(Site, 
                                 Species,
                                 cap_per_m2) %>%
                          spread(Species, cap_per_m2) %>%
                          rename(qrf_chnk_per_m2 = Chinook,
                                 qrf_sthd_per_m2 = Steelhead))) %>%
  mutate(chnk_per_m = if_else(!is.na(qrf_chnk_per_m),
                              qrf_chnk_per_m,
                              chnk_per_m),
         chnk_per_m_se = if_else(!is.na(qrf_chnk_per_m),
                                 as.numeric(NA),
                                 chnk_per_m_se),
         chnk_per_m2 = if_else(!is.na(qrf_chnk_per_m2),
                               qrf_chnk_per_m2,
                               chnk_per_m2),
         chnk_per_m2_se = if_else(!is.na(qrf_chnk_per_m2),
                                  as.numeric(NA),
                                  chnk_per_m2_se)) %>%
  mutate(sthd_per_m = if_else(!is.na(qrf_sthd_per_m),
                              qrf_sthd_per_m,
                              sthd_per_m),
         sthd_per_m_se = if_else(!is.na(qrf_sthd_per_m),
                                 as.numeric(NA),
                                 sthd_per_m_se),
         sthd_per_m2 = if_else(!is.na(qrf_sthd_per_m2),
                               qrf_sthd_per_m2,
                               sthd_per_m2),
         sthd_per_m2_se = if_else(!is.na(qrf_sthd_per_m2),
                                  as.numeric(NA),
                                  sthd_per_m2_se)) %>%
  select(-starts_with('qrf'))


save(gaa_covars,
     mod_data_weights,
     model_svy_df,
     all_preds,
     file = 'output/modelFits/extrap_juv_winter.rda')

#---------------------------
# create a shapefile
load('output/modelFits/extrap_juv_winter.rda')
data("chnk_domain")

all_preds_sf = all_preds %>%
  select(Site, Lon:model) %>%
  st_as_sf(coords = c('Lon', 'Lat'),
           crs = 4326) %>%
  st_transform(st_crs(chnk_domain))

# save it
# as shapefile
st_write(all_preds_sf,
         dsn = 'output/shapefiles/Win_Juv_Capacity.shp',
         driver = 'ESRI Shapefile',
         delete_layer = T)

# as GPKG
st_write(all_preds_sf,
         dsn = 'output/gpkg/Win_Juv_Capacity.gpkg',
         driver = 'GPKG',
         delete_layer = T)
